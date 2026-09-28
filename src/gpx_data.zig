//! What parsing a GPX file returns: metadata, waypoints, the trace, and the legs, sections
//! and stages between waypoints.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const LegStats = @import("leg.zig").LegStats;
const SectionStats = @import("section.zig").SectionStats;
const StageStats = @import("stage.zig").StageStats;
const PlanEntry = @import("calibration.zig").PlanEntry;
const Trace = @import("trace.zig").Trace;

pub const Metadata = struct {
    name: ?[]const u8,
    description: ?[]const u8,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.description) |description| allocator.free(description);
        self.* = undefined;
    }
};

/// The `<type>` values that bound sections and stages. Any other `<type>` also bounds a
/// section, since sections split on every typed waypoint.
pub const type_start = "Start";
pub const type_time_barrier = "TimeBarrier";
pub const type_life_base = "LifeBase";
pub const type_arrival = "Arrival";

pub const Waypoint = struct {
    latitude: f64,
    longitude: f64,
    /// `<ele>`.
    elevation_m: ?f64 = null,
    /// `<name>`, or empty when absent.
    name: []const u8,
    /// `<desc>`, `<cmt>` and `<sym>`.
    description: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
    /// `<type>`: "Start", "TimeBarrier", "LifeBase", "Arrival", anything else, or absent.
    type_name: ?[]const u8 = null,
    /// `<time>`: the cutoff at this checkpoint.
    epoch_s: ?i64,
    /// `<stopDuration>`: the planned stop here.
    stop_s: ?u32 = null,

    /// Frees the strings. `name` is always owned, even when empty.
    pub fn deinit(self: *Waypoint, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |description| allocator.free(description);
        if (self.comment) |comment| allocator.free(comment);
        if (self.symbol) |symbol| allocator.free(symbol);
        if (self.type_name) |type_name| allocator.free(type_name);
        self.* = undefined;
    }

    fn is_type(self: *const Waypoint, type_name: []const u8) bool {
        assert(type_name.len > 0);
        const own = self.type_name orelse return false;
        return std.mem.eql(u8, own, type_name);
    }

    /// Start, LifeBase and Arrival bound stages.
    pub fn is_stage_boundary(self: *const Waypoint) bool {
        const result = self.is_type(type_start) or self.is_type(type_life_base) or
            self.is_type(type_arrival);
        // Every stage boundary is also a section boundary: stages group sections.
        assert(!result or self.is_section_boundary());
        return result;
    }

    /// Every typed waypoint bounds a section.
    pub fn is_section_boundary(self: *const Waypoint) bool {
        return self.type_name != null;
    }

    pub fn is_finish(self: *const Waypoint) bool {
        const result = self.is_type(type_arrival);
        assert(!result or self.is_stage_boundary());
        return result;
    }
};

pub const GPXData = struct {
    trace: Trace,
    waypoints: []Waypoint,
    /// Between consecutive waypoints; null with fewer than 2 waypoints.
    legs: ?[]const LegStats,
    /// Between consecutive section and stage boundaries; null with fewer than 2 of them.
    sections: ?[]const SectionStats,
    stages: ?[]const StageStats,
    /// When the runner reaches and leaves each section boundary; null like `sections`.
    plan: ?[]const PlanEntry,
    metadata: Metadata,
    /// Every track point, unsimplified, as [lat, lon, ele, lat, lon, ele, ...], so Zigar
    /// hands JavaScript one Float64Array for full-resolution rendering, not a proxy per point.
    points_full_resolution: []f64,

    pub fn deinit(self: *GPXData, allocator: std.mem.Allocator) void {
        assert(self.points_full_resolution.len % 3 == 0);
        self.metadata.deinit(allocator);
        self.trace.deinit(allocator);
        allocator.free(self.points_full_resolution);
        for (self.waypoints) |*waypoint| waypoint.deinit(allocator);
        allocator.free(self.waypoints);
        if (self.legs) |legs| allocator.free(legs);
        if (self.sections) |sections| allocator.free(sections);
        if (self.stages) |stages| allocator.free(stages);
        if (self.plan) |plan| allocator.free(plan);
        self.* = undefined;
    }
};

fn waypoint_typed(type_name: ?[]const u8) Waypoint {
    return .{ .latitude = 0, .longitude = 0, .name = "", .type_name = type_name, .epoch_s = null };
}

test "Waypoint: which types bound stages, sections and the finish" {
    const Case = struct { type_name: ?[]const u8, stage: bool, section: bool, finish: bool };
    const cases = [_]Case{
        .{ .type_name = type_start, .stage = true, .section = true, .finish = false },
        .{ .type_name = type_time_barrier, .stage = false, .section = true, .finish = false },
        .{ .type_name = type_life_base, .stage = true, .section = true, .finish = false },
        .{ .type_name = type_arrival, .stage = true, .section = true, .finish = true },
        .{ .type_name = "Water", .stage = false, .section = true, .finish = false },
        .{ .type_name = "arrival", .stage = false, .section = true, .finish = false },
        .{ .type_name = null, .stage = false, .section = false, .finish = false },
    };
    for (cases) |case| {
        const waypoint = waypoint_typed(case.type_name);
        try testing.expectEqual(case.stage, waypoint.is_stage_boundary());
        try testing.expectEqual(case.section, waypoint.is_section_boundary());
        try testing.expectEqual(case.finish, waypoint.is_finish());
    }
}

test "Metadata.deinit: frees what it owns, and handles null" {
    var metadata: Metadata = .{
        .name = try testing.allocator.dupe(u8, "Trail Name"),
        .description = try testing.allocator.dupe(u8, "A description"),
    };
    metadata.deinit(testing.allocator);
    var empty: Metadata = .{ .name = null, .description = null };
    empty.deinit(testing.allocator);
}

test "Waypoint.deinit: frees every string, and handles null" {
    var full: Waypoint = .{
        .latitude = 48.85,
        .longitude = 2.35,
        .name = try testing.allocator.dupe(u8, "Checkpoint 1"),
        .description = try testing.allocator.dupe(u8, "A checkpoint"),
        .comment = try testing.allocator.dupe(u8, "A comment"),
        .symbol = try testing.allocator.dupe(u8, "Flag"),
        .type_name = try testing.allocator.dupe(u8, type_time_barrier),
        .epoch_s = 1_700_000_000,
    };
    full.deinit(testing.allocator);
    var plain: Waypoint = .{
        .latitude = 0,
        .longitude = 0,
        .name = try testing.allocator.dupe(u8, ""),
        .epoch_s = null,
    };
    plain.deinit(testing.allocator);
}
