//! Sections: the intervals between consecutive section boundaries. A thin wrapper over
//! calibration.zig, which holds the boundary resolution and physics shared by sections and
//! stages.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Trace = @import("trace.zig").Trace;
const Waypoint = @import("gpx_data.zig").Waypoint;
const pace_model = @import("pace_model.zig");
const calibration = @import("calibration.zig");

pub const SectionStats = calibration.SectionStats;
pub const Recalibration = calibration.Recalibration;
pub const RecalibratedETA = calibration.RecalibratedETA;

/// Returns the statistics of each section, or null with fewer than two section boundaries.
/// The caller owns the result.
pub fn sections_compute(
    allocator: std.mem.Allocator,
    trace: *const Trace,
    waypoints: []const Waypoint,
    settings: *const pace_model.Settings,
) !?[]SectionStats {
    const sections = try calibration.intervals_compute(
        SectionStats,
        .section,
        allocator,
        trace,
        waypoints,
        settings,
    ) orelse return null;
    assert(sections.len < waypoints.len);
    return sections;
}

/// Recalibrates the remaining sections' ETAs from the runner's progress. See
/// `calibration.recalibrate`.
pub fn recalibrate(
    allocator: std.mem.Allocator,
    trace: *const Trace,
    waypoints: []const Waypoint,
    index_current: usize,
    elapsed_s_actual: f64,
    settings: *const pace_model.Settings,
) !?Recalibration {
    assert(elapsed_s_actual >= 0);
    assert(index_current < trace.points.len or trace.points.len == 0);
    return calibration.recalibrate(
        allocator,
        trace,
        waypoints,
        .section,
        index_current,
        elapsed_s_actual,
        settings,
    );
}

/// No planned LifeBase stop, so the tests see moving time only unless they set one.
const settings_no_stop: pace_model.Settings = .{ .life_base_stop_s = 0 };

/// A waypoint for tests, borrowing its strings.
fn waypoint_test(
    latitude: f64,
    longitude: f64,
    name: []const u8,
    type_name: ?[]const u8,
    epoch_s: ?i64,
) Waypoint {
    return .{
        .latitude = latitude,
        .longitude = longitude,
        .name = name,
        .type_name = type_name,
        .epoch_s = epoch_s,
    };
}

test "sections_compute: returns null with no section boundaries" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.0, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 110.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "A", null, null),
        waypoint_test(0.001, 0.0, "B", null, null),
    };
    const result = try sections_compute(allocator, &trace, &waypoints, &.{});
    try testing.expect(result == null);
}

test "sections_compute: returns null with only one section boundary" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.0, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 110.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "Start", "Start", null),
        waypoint_test(0.001, 0.0, "Plain", null, null),
    };
    const result = try sections_compute(allocator, &trace, &waypoints, &.{});
    try testing.expect(result == null);
}

test "sections_compute: basic two-boundary section" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 105.0 },
        [3]f64{ 0.002, 0.0, 110.0 },
        [3]f64{ 0.003, 0.0, 115.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.003, 0.0, "TB1", "TimeBarrier", null),
    };

    const sections = try sections_compute(allocator, &trace, &waypoints, &.{});
    defer if (sections) |slice| allocator.free(slice);

    try testing.expect(sections != null);
    try testing.expectEqual(@as(usize, 1), sections.?.len);
    try testing.expectEqual(@as(usize, 0), sections.?[0].section_index);
    try testing.expect(sections.?[0].distance_m > 0.0);
    try testing.expect(sections.?[0].point_count > 0);
}

test "sections_compute: plain (untyped) waypoints are ignored" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 102.0 },
        [3]f64{ 0.002, 0.0, 104.0 },
        [3]f64{ 0.003, 0.0, 106.0 },
        [3]f64{ 0.004, 0.0, 108.0 },
        [3]f64{ 0.005, 0.0, 110.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    // 3 section boundaries with plain waypoints interspersed
    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.001, 0.0, "Plain1", null, null),
        waypoint_test(0.002, 0.0, "TB1", "TimeBarrier", null),
        waypoint_test(0.003, 0.0, "Plain2", null, null),
        waypoint_test(0.005, 0.0, "End", "Arrival", null),
    };

    const sections = try sections_compute(allocator, &trace, &waypoints, &.{});
    defer if (sections) |slice| allocator.free(slice);

    // 2 sections: Start→TB1 and TB1→Arrival; plain waypoints are skipped
    try testing.expect(sections != null);
    try testing.expectEqual(@as(usize, 2), sections.?.len);
}

test "sections_compute: stage_index increments at LifeBase boundary" {
    const allocator = testing.allocator;
    var points = try allocator.alloc([3]f64, 12);
    defer allocator.free(points);
    for (0..12) |index| {
        const fraction = @as(f64, @floatFromInt(index)) * 0.001;
        points[index] = [3]f64{ fraction, 0.0, 100.0 + fraction * 500.0 };
    }
    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    // Sections: Start→TB1→LifeBase→TB2→Arrival
    // Stage 0: Start→TB1, TB1→LifeBase  (sections 0 and 1)
    // Stage 1: LifeBase→TB2, TB2→Arrival (sections 2 and 3)
    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.003, 0.0, "TB1", "TimeBarrier", null),
        waypoint_test(0.006, 0.0, "LB1", "LifeBase", null),
        waypoint_test(0.009, 0.0, "TB2", "TimeBarrier", null),
        waypoint_test(0.011, 0.0, "Arrival", "Arrival", null),
    };

    const sections = try sections_compute(allocator, &trace, &waypoints, &.{});
    defer if (sections) |slice| allocator.free(slice);

    try testing.expect(sections != null);
    try testing.expectEqual(@as(usize, 4), sections.?.len);
    // Sections 0 and 1 belong to stage 0 (before LifeBase)
    try testing.expectEqual(@as(usize, 0), sections.?[0].stage_index);
    try testing.expectEqual(@as(usize, 0), sections.?[1].stage_index);
    // Sections 2 and 3 belong to stage 1 (after LifeBase)
    try testing.expectEqual(@as(usize, 1), sections.?[2].stage_index);
    try testing.expectEqual(@as(usize, 1), sections.?[3].stage_index);
}

test "sections_compute: duration_s_cutoff computed from timestamps" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 105.0 },
        [3]f64{ 0.002, 0.0, 110.0 },
        [3]f64{ 0.003, 0.0, 115.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", 1_000_000),
        waypoint_test(0.003, 0.0, "End", "TimeBarrier", 1_007_200),
    };

    const sections = try sections_compute(allocator, &trace, &waypoints, &.{});
    defer if (sections) |slice| allocator.free(slice);

    try testing.expect(sections != null);
    try testing.expectEqual(@as(usize, 1), sections.?.len);
    try testing.expect(sections.?[0].duration_s_cutoff != null);
    try testing.expectEqual(@as(i64, 7200), sections.?[0].duration_s_cutoff.?);
    try testing.expectEqual(@as(i64, 1_000_000), sections.?[0].epoch_s_start.?);
    try testing.expectEqual(@as(i64, 1_007_200), sections.?[0].epoch_s_end.?);
}

test "sections_compute: duration_s_cutoff is null without timestamps" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 105.0 },
        [3]f64{ 0.002, 0.0, 110.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.002, 0.0, "End", "Arrival", null),
    };

    const sections = try sections_compute(allocator, &trace, &waypoints, &.{});
    defer if (sections) |slice| allocator.free(slice);

    try testing.expect(sections != null);
    try testing.expectEqual(@as(?i64, null), sections.?[0].duration_s_cutoff);
    try testing.expectEqual(@as(?i64, null), sections.?[0].epoch_s_start);
    try testing.expectEqual(@as(?i64, null), sections.?[0].epoch_s_end);
    try testing.expectEqual(@as(?f64, null), sections.?[0].cutoff_ratio);
}

test "sections_compute: cutoff_ratio is duration_s_estimated / duration_s_cutoff" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 100.0 },
        [3]f64{ 0.002, 0.0, 100.0 },
        [3]f64{ 0.003, 0.0, 100.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    // Give a very generous cutoff (10 hours) so the ratio is clearly < 1.0
    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", 1_000_000),
        waypoint_test(0.003, 0.0, "End", "TimeBarrier", 1_000_000 + 36_000),
    };

    const sections = try sections_compute(allocator, &trace, &waypoints, &.{});
    defer if (sections) |slice| allocator.free(slice);

    try testing.expect(sections != null);
    const slice = sections.?[0];
    try testing.expect(slice.cutoff_ratio != null);
    // ratio = duration_s_estimated / 36000
    try testing.expectApproxEqAbs(
        slice.duration_s_estimated / 36_000.0,
        slice.cutoff_ratio.?,
        1e-9,
    );
    // A few hundred metres at walking pace should be well under a 10-hour cutoff
    try testing.expect(slice.cutoff_ratio.? < 1.0);
}

test "sections_compute: LifeBase recovery reduces fatigue in subsequent section" {
    // Two identical legs. In the LifeBase variant the midpoint is a LifeBase (recovery applied);
    // in the TimeBarrier variant it is not. The second section should be faster with LifeBase.
    const allocator = testing.allocator;
    var points = try allocator.alloc([3]f64, 9);
    defer allocator.free(points);
    for (0..9) |index| {
        points[index] = [3]f64{ @as(f64, @floatFromInt(index)) * 0.001, 0.0, 100.0 };
    }

    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    const waypoints_life_base = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.004, 0.0, "LB", "LifeBase", null),
        waypoint_test(0.008, 0.0, "Arrival", "Arrival", null),
    };
    const waypoints_time_barrier = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.004, 0.0, "TB", "TimeBarrier", null),
        waypoint_test(0.008, 0.0, "Arrival", "Arrival", null),
    };

    // Pass 0 for life_base_stop_s: this test is about fatigue recovery, not stop time.
    const sections_life_base = try sections_compute(
        allocator,
        &trace,
        &waypoints_life_base,
        &settings_no_stop,
    );
    defer if (sections_life_base) |slice| allocator.free(slice);
    const sections_time_barrier = try sections_compute(
        allocator,
        &trace,
        &waypoints_time_barrier,
        &settings_no_stop,
    );
    defer if (sections_time_barrier) |slice| allocator.free(slice);

    try testing.expect(sections_life_base != null);
    try testing.expect(sections_time_barrier != null);
    // First section is identical (same accumulated fatigue entering it, no stop time)
    try testing.expectApproxEqAbs(
        sections_life_base.?[0].duration_s_estimated,
        sections_time_barrier.?[0].duration_s_estimated,
        1e-6,
    );
    // Second section is faster with LifeBase recovery
    const duration_s_time_barrier = sections_time_barrier.?[1].duration_s_estimated;
    try testing.expect(sections_life_base.?[1].duration_s_estimated < duration_s_time_barrier);
}

test "sections_compute: circadian penalty slows night sections" {
    // Same single-section route run twice: once starting at noon UTC, once at 3:30 UTC.
    // The night run should have a longer estimated duration.
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 100.0 },
        [3]f64{ 0.002, 0.0, 100.0 },
        [3]f64{ 0.003, 0.0, 100.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const noon_utc: i64 = 12 * 3600;
    const night_utc: i64 = 3 * 3600 + 30 * 60; // 03:30 UTC — circadian peak

    const waypoints_day = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", noon_utc),
        waypoint_test(0.003, 0.0, "Arrival", "Arrival", null),
    };
    const waypoints_night = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", night_utc),
        waypoint_test(0.003, 0.0, "Arrival", "Arrival", null),
    };

    const sections_day = try sections_compute(allocator, &trace, &waypoints_day, &.{});
    defer if (sections_day) |slice| allocator.free(slice);
    const sections_night = try sections_compute(allocator, &trace, &waypoints_night, &.{});
    defer if (sections_night) |slice| allocator.free(slice);

    try testing.expect(sections_day != null);
    try testing.expect(sections_night != null);
    const duration_s_day = sections_day.?[0].duration_s_estimated;
    try testing.expect(sections_night.?[0].duration_s_estimated > duration_s_day);
}

test "sections_compute: stop_s is added to duration_s_estimated" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 100.0 },
        [3]f64{ 0.002, 0.0, 100.0 },
        [3]f64{ 0.003, 0.0, 100.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const stop_s: u32 = 3600; // 1 hour stop
    const waypoints_stop = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        blk: {
            var waypoint = waypoint_test(0.003, 0.0, "LB", "LifeBase", null);
            waypoint.stop_s = stop_s;
            break :blk waypoint;
        },
    };
    const waypoints_no_stop = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.003, 0.0, "LB", "LifeBase", null),
    };

    // Explicit stop_s overrides the default; pass 0 as default for the no-stop baseline.
    const sections_stop = try sections_compute(
        allocator,
        &trace,
        &waypoints_stop,
        &settings_no_stop,
    );
    defer if (sections_stop) |slice| allocator.free(slice);
    const sections_no_stop = try sections_compute(
        allocator,
        &trace,
        &waypoints_no_stop,
        &settings_no_stop,
    );
    defer if (sections_no_stop) |slice| allocator.free(slice);

    try testing.expect(sections_stop != null);
    try testing.expect(sections_no_stop != null);
    // waypoints_stop has explicit stop_s=3600; waypoints_no_stop has none and default=0
    try testing.expectApproxEqAbs(
        sections_no_stop.?[0].duration_s_estimated + @as(f64, @floatFromInt(stop_s)),
        sections_stop.?[0].duration_s_estimated,
        1e-6,
    );
    try testing.expectEqual(@as(?u32, stop_s), sections_stop.?[0].stop_s);
    try testing.expectEqual(@as(?u32, null), sections_no_stop.?[0].stop_s);
}

test "sections_compute: adverse weather at a checkpoint slows that section" {
    // Two identical single sections; the weather variant has a hot/wet forecast at
    // the arrival checkpoint, which must increase that section's estimated duration.
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 100.0 },
        [3]f64{ 0.002, 0.0, 100.0 },
        [3]f64{ 0.003, 0.0, 100.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.003, 0.0, "Arrival", "Arrival", null),
    };

    const sections_calm = try sections_compute(allocator, &trace, &waypoints, &settings_no_stop);
    defer if (sections_calm) |slice| allocator.free(slice);

    const names = [_][]const u8{"Arrival"};
    const values = [_]pace_model.WeatherConditions{
        .{
            .temperature_c = 32.0,
            .humidity_percent = 85.0,
            .wind_kmh = 35.0,
            .precipitation_probability_percent = 80.0,
        },
    };
    const lookup = pace_model.WeatherLookup{ .names = &names, .values = &values };
    const settings_hot: pace_model.Settings = .{ .life_base_stop_s = 0, .weather = lookup };
    const sections_hot = try sections_compute(allocator, &trace, &waypoints, &settings_hot);
    defer if (sections_hot) |slice| allocator.free(slice);

    try testing.expect(sections_calm != null);
    try testing.expect(sections_hot != null);
    const duration_s_calm_first = sections_calm.?[0].duration_s_estimated;
    try testing.expect(sections_hot.?[0].duration_s_estimated > duration_s_calm_first);
    // A forecast keyed to a different checkpoint name must not change anything.
    const other_names = [_][]const u8{"Nowhere"};
    const other_lookup = pace_model.WeatherLookup{ .names = &other_names, .values = &values };
    const settings_other: pace_model.Settings = .{ .life_base_stop_s = 0, .weather = other_lookup };
    const sections_other = try sections_compute(allocator, &trace, &waypoints, &settings_other);
    defer if (sections_other) |slice| allocator.free(slice);
    const duration_s_calm = sections_calm.?[0].duration_s_estimated;
    try testing.expectApproxEqAbs(duration_s_calm, sections_other.?[0].duration_s_estimated, 1e-6);
}

// recalibrate (section wrapper).
// The calibration physics are covered in calibration.zig. This integration test
// only verifies the section-granularity wrapper agrees with the a-priori model.

test "recalibrate: at the start reproduces the a-priori section total at factor 1.0" {
    const allocator = testing.allocator;
    var points = try allocator.alloc([3]f64, 30);
    defer allocator.free(points);
    for (0..30) |index| {
        points[index] = [3]f64{ @as(f64, @floatFromInt(index)) * 0.001, 0.0, 100.0 };
    }
    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    // Start(idx0) / TB1(idx10) / TB2(idx20) / Arrival(idx29) — three sections.
    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.010, 0.0, "TB1", "TimeBarrier", null),
        waypoint_test(0.020, 0.0, "TB2", "TimeBarrier", null),
        waypoint_test(0.029, 0.0, "Arrival", "Arrival", null),
    };

    const predicted = try sections_compute(allocator, &trace, &waypoints, &settings_no_stop);
    defer if (predicted) |slice| allocator.free(slice);
    try testing.expect(predicted != null);
    var predicted_total_s: f64 = 0.0;
    for (predicted.?) |slice| predicted_total_s += slice.duration_s_estimated;

    var result = try recalibrate(allocator, &trace, &waypoints, 0, 0.0, &settings_no_stop);
    defer if (result) |*recalibration| recalibration.deinit(allocator);
    try testing.expect(result != null);
    const recalibration = result.?;

    try testing.expectEqual(@as(f64, 1.0), recalibration.calibration_factor);
    try testing.expectEqual(@as(usize, 3), recalibration.etas.len);
    for (recalibration.etas, 0..) |eta, index| {
        const expected_s = predicted.?[index].duration_s_estimated;
        try testing.expectApproxEqAbs(expected_s, eta.duration_s_remaining, 1e-6);
    }
    const total_s = recalibration.etas[recalibration.etas.len - 1].duration_s_remaining_cumulative;
    try testing.expectApproxEqAbs(predicted_total_s, total_s, 1e-6);
}
