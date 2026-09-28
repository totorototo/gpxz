const std = @import("std");
const assert = std.debug.assert;
const gpxz = @import("gpxz");

/// Multi-day ultra GPX files are a few MiB; this leaves ample headroom.
const file_size_max = 64 * 1024 * 1024;

/// Far more than the options take (one path plus four flags with values), so a longer argv
/// is a usage error rather than a loop to walk.
const arguments_max = 16;

const usage =
    \\usage: gpxz [--json] [--pace <s/km>] [--fatigue <k>] [--life-base-stop <s>] <file.gpx>
    \\  --json             print the route (totals, climbs, waypoints, legs, sections,
    \\                     stages, plan) as JSON on stdout instead of the text summary
    \\  --pace             flat-terrain base pace in seconds per km (default 500 = 8:20/km)
    \\  --fatigue          cumulative fatigue coefficient (default 0.002)
    \\  --life-base-stop   planned stop at each LifeBase in seconds (default 3600)
    \\  via build: zig build run -- [options] <file.gpx>
    \\
;

const Options = struct {
    json: bool = false,
    settings: gpxz.Settings = .{},
    path: []const u8,
};

/// What `--json` prints: everything in GPXData except the per-point arrays. Those are
/// several MiB on a long route and are only useful to a renderer, not to a reader.
const Report = struct {
    name: ?[]const u8,
    description: ?[]const u8,
    point_count: u64,
    distance_m: f64,
    elevation_gain_m: f64,
    elevation_loss_m: f64,
    climbs: []const gpxz.ClimbStats,
    waypoints: []const gpxz.Waypoint,
    legs: ?[]const gpxz.LegStats,
    sections: ?[]const gpxz.SectionStats,
    stages: ?[]const gpxz.StageStats,
    plan: ?[]const gpxz.PlanEntry,

    fn from_data(data: *const gpxz.GPXData) Report {
        const report: Report = .{
            .name = data.metadata.name,
            .description = data.metadata.description,
            .point_count = point_count(data),
            .distance_m = data.trace.distance_m,
            .elevation_gain_m = data.trace.elevation_gain_m,
            .elevation_loss_m = data.trace.elevation_loss_m,
            .climbs = data.trace.climbs,
            .waypoints = data.waypoints,
            .legs = data.legs,
            .sections = data.sections,
            .stages = data.stages,
            .plan = data.plan,
        };
        assert(report.distance_m >= 0);
        assert(report.climbs.len <= report.point_count);
        return report;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const options = options_parse(arguments) orelse {
        // A usage error is the user's mistake, not a crash: exit 2 without an error trace.
        std.debug.print(usage, .{});
        std.process.exit(2);
    };
    assert(options.path.len > 0);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        options.path,
        allocator,
        .limited(file_size_max),
    ) catch |err| {
        // A missing or unreadable file is the user's input, not a bug: no error trace.
        std.debug.print("gpxz: {s}: {t}\n", .{ options.path, err });
        std.process.exit(1);
    };
    defer allocator.free(bytes);
    assert(bytes.len <= file_size_max);

    var data = gpxz.parse(allocator, bytes, &options.settings) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // A malformed GPX is the user's input, not a bug: no error trace.
        else => |parse_error| {
            std.debug.print("gpxz: {s}: {t}\n", .{ options.path, parse_error });
            std.process.exit(1);
        },
    };
    defer data.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    output_write(&stdout_writer.interface, &data, options.json) catch |err| {
        // The reader closed the pipe early (`gpxz --json r.gpx | head`): that is how the
        // output was meant to be used, not a failure.
        if (stdout_writer.err) |write_err| {
            if (write_err == error.BrokenPipe) return;
        }
        return err;
    };
}

fn output_write(writer: *std.Io.Writer, data: *const gpxz.GPXData, json: bool) !void {
    if (json) {
        const options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };
        try std.json.Stringify.value(Report.from_data(data), options, writer);
        try writer.writeByte('\n');
    } else {
        try summary_write(writer, data);
    }
    try writer.flush();
}

/// Returns null on any usage error: too many arguments, unknown flag, missing or unparsable
/// value, or not exactly one path.
fn options_parse(arguments: []const [:0]const u8) ?Options {
    // argv[0], the program name, is always present.
    assert(arguments.len >= 1);
    if (arguments.len > arguments_max) return null;

    var options: Options = .{ .path = "" };
    var path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--json")) {
            options.json = true;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            index += 1;
            if (index >= arguments.len) return null;
            if (!option_value_parse(&options, argument, arguments[index])) return null;
        } else {
            if (path != null) return null;
            path = argument;
        }
    }
    options.path = path orelse return null;
    if (options.path.len == 0) return null;

    assert(options.settings.pace_base_s_per_km > 0);
    assert(options.settings.fatigue_coefficient >= 0);
    return options;
}

/// Sets the option `flag` names from `value`. Returns false for an unknown flag or a value
/// that doesn't parse or is out of range, so NaN and negative paces are rejected here.
fn option_value_parse(options: *Options, flag: []const u8, value: []const u8) bool {
    assert(std.mem.startsWith(u8, flag, "--"));
    if (std.mem.eql(u8, flag, "--pace")) {
        const pace = std.fmt.parseFloat(f64, value) catch return false;
        if (!(pace > 0) or !std.math.isFinite(pace)) return false;
        options.settings.pace_base_s_per_km = pace;
    } else if (std.mem.eql(u8, flag, "--fatigue")) {
        const fatigue = std.fmt.parseFloat(f64, value) catch return false;
        if (!(fatigue >= 0) or !std.math.isFinite(fatigue)) return false;
        options.settings.fatigue_coefficient = fatigue;
    } else if (std.mem.eql(u8, flag, "--life-base-stop")) {
        options.settings.life_base_stop_s = std.fmt.parseInt(u32, value, 10) catch return false;
    } else {
        return false;
    }
    return true;
}

/// GPXData.points_full_resolution is flattened as [lat, lon, ele, ...], three f64 per point.
fn point_count(data: *const gpxz.GPXData) u64 {
    assert(data.points_full_resolution.len % 3 == 0);
    const count: u64 = data.points_full_resolution.len / 3;
    assert(count >= data.trace.points.len);
    return count;
}

fn summary_write(writer: *std.Io.Writer, data: *const gpxz.GPXData) std.Io.Writer.Error!void {
    const trace = &data.trace;
    assert(trace.distance_m >= 0);
    assert(trace.elevation_gain_m >= 0);

    try writer.print("{s}\n", .{data.metadata.name orelse "(unnamed route)"});
    try writer.print("  points     {d}\n", .{point_count(data)});
    try writer.print("  distance   {d:.2} km\n", .{trace.distance_m / 1000.0});
    try writer.print("  D+ / D-    {d:.0} m / {d:.0} m\n", .{
        trace.elevation_gain_m,
        trace.elevation_loss_m,
    });
    try writer.print("  waypoints  {d}\n", .{data.waypoints.len});

    try writer.print("\nclimbs ({d})\n", .{trace.climbs.len});
    for (trace.climbs, 1..) |climb, number| {
        assert(climb.index_start < climb.index_end);
        const line = "  {d:>3}. km {d:>6.1}  {d:>5.1} km  +{d:>4.0} m  {d:>4.1} %  top {d:.0} m\n";
        try writer.print(line, .{
            number,
            climb.distance_m_start / 1000.0,
            climb.distance_m / 1000.0,
            climb.elevation_gain_m,
            climb.gradient_percent_average,
            climb.elevation_m_summit,
        });
    }

    if (data.stages) |stages| {
        try writer.print("\nstages ({d})\n", .{stages.len});
        for (stages) |interval| try interval_write(writer, interval);
    }
    if (data.sections) |sections| {
        try writer.print("\nsections ({d})\n", .{sections.len});
        for (sections) |interval| try interval_write(writer, interval);
    }
    if (data.plan) |plan| {
        try writer.print("\nplan ({d})\n", .{plan.len});
        for (plan) |*entry| try plan_entry_write(writer, entry);
    }
}

/// One line per checkpoint: where it is, when the runner arrives, and the margin on its
/// cutoff when it has one.
fn plan_entry_write(
    writer: *std.Io.Writer,
    entry: *const gpxz.PlanEntry,
) std.Io.Writer.Error!void {
    assert(entry.distance_m >= 0);
    assert(entry.duration_s_departure >= entry.duration_s_arrival);
    try writer.print("  km {d:>6.1}  +{d:>5.0} m  at ", .{
        entry.distance_m / 1000.0,
        entry.elevation_gain_m,
    });
    try duration_write(writer, entry.duration_s_arrival);
    if (entry.stop_s > 0) {
        try writer.writeAll(" (stop ");
        try duration_write(writer, entry.stop_s);
        try writer.writeByte(')');
    }
    try writer.print("  {s}", .{entry.name});
    if (entry.margin_s) |margin_s| {
        try writer.writeAll("  margin ");
        if (margin_s < 0) try writer.writeByte('-');
        try duration_write(writer, @abs(margin_s));
    }
    try writer.writeByte('\n');
}

/// One line per section or stage. `interval` is a SectionStats or a StageStats, which share
/// every field printed here.
fn interval_write(writer: *std.Io.Writer, interval: anytype) std.Io.Writer.Error!void {
    comptime assert(@TypeOf(interval) == gpxz.SectionStats or
        @TypeOf(interval) == gpxz.StageStats);
    assert(interval.index_start <= interval.index_end);

    try writer.print("  {s} → {s}  {d:.1} km  +{d:.0}/-{d:.0} m  est ", .{
        interval.location_start,
        interval.location_end,
        interval.distance_m / 1000.0,
        interval.elevation_gain_m,
        interval.elevation_loss_m,
    });
    try duration_write(writer, interval.duration_s_estimated);
    if (interval.cutoff_ratio) |ratio| {
        assert(ratio >= 0);
        try writer.print("  cutoff {d:.0} %", .{ratio * 100.0});
    }
    try writer.writeByte('\n');
}

/// Seconds as `HhMM`, rounded to the minute.
fn duration_write(writer: *std.Io.Writer, seconds: f64) std.Io.Writer.Error!void {
    // Durations come from the pace model, which never produces a negative or non-finite one.
    assert(std.math.isFinite(seconds));
    assert(seconds >= 0);
    const minutes_total: u64 = @intFromFloat(@round(seconds / 60.0));
    try writer.print("{d}h{d:0>2}", .{ minutes_total / 60, minutes_total % 60 });
}

test "options_parse: path only uses defaults" {
    const options = options_parse(&.{ "gpxz", "route.gpx" }).?;
    try std.testing.expectEqualStrings("route.gpx", options.path);
    try std.testing.expect(!options.json);
    try std.testing.expectEqual(@as(u32, 3600), options.settings.life_base_stop_s);
}

test "options_parse: flags with values" {
    const options = options_parse(&.{
        "gpxz", "--json", "--pace", "420", "--fatigue", "0.004", "--life-base-stop", "0", "r.gpx",
    }).?;
    try std.testing.expect(options.json);
    try std.testing.expectApproxEqAbs(@as(f64, 420), options.settings.pace_base_s_per_km, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), options.settings.fatigue_coefficient, 1e-9);
    try std.testing.expectEqual(@as(u32, 0), options.settings.life_base_stop_s);
}

test "options_parse: usage errors return null" {
    try std.testing.expect(options_parse(&.{"gpxz"}) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "a.gpx", "b.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--pace" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--pace", "fast", "a.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--pace", "0", "a.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--life-base-stop", "-1", "a.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--nope", "x", "a.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "" }) == null);
}

test "options_parse: non-finite values return null" {
    try std.testing.expect(options_parse(&.{ "gpxz", "--pace", "nan", "a.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--pace", "inf", "a.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--fatigue", "nan", "a.gpx" }) == null);
    try std.testing.expect(options_parse(&.{ "gpxz", "--fatigue", "-0.1", "a.gpx" }) == null);
}

test "options_parse: argument count at and past arguments_max" {
    // Repeating --json is harmless, so it pads argv to an exact length.
    var arguments: [arguments_max + 1][:0]const u8 = @splat("--json");
    arguments[0] = "gpxz";
    arguments[arguments_max - 1] = "a.gpx";
    try std.testing.expect(options_parse(arguments[0..arguments_max]) != null);
    try std.testing.expect(options_parse(&arguments) == null);
}

test "duration_write: rounds to the minute" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try duration_write(&out.writer, 3 * 3600 + 5 * 60 + 31);
    try std.testing.expectEqualStrings("3h06", out.written());
}

test "plan_entry_write: stop and a missed cutoff" {
    const entry: gpxz.PlanEntry = .{
        .name = "LB1",
        .type_name = "LifeBase",
        .index = 10,
        .latitude = 45.0,
        .longitude = 6.0,
        .elevation_m = 1200.0,
        .distance_m = 42_195,
        .elevation_gain_m = 2400,
        .elevation_loss_m = 2000,
        .duration_s_arrival = 6 * 3600 + 30 * 60,
        .stop_s = 3600,
        .duration_s_departure = 7 * 3600 + 30 * 60,
        .epoch_s_arrival = null,
        .epoch_s_cutoff = null,
        .margin_s = -15 * 60,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try plan_entry_write(&out.writer, &entry);
    const expected = "  km   42.2  + 2400 m  at 6h30 (stop 1h00)  LB1  margin -0h15\n";
    try std.testing.expectEqualStrings(expected, out.written());

    // No stop and no cutoff: neither is printed.
    var bare = entry;
    bare.stop_s = 0;
    bare.duration_s_departure = bare.duration_s_arrival;
    bare.margin_s = null;
    out.clearRetainingCapacity();
    try plan_entry_write(&out.writer, &bare);
    try std.testing.expectEqualStrings("  km   42.2  + 2400 m  at 6h30  LB1\n", out.written());
}

const test_gpx =
    \\<?xml version="1.0"?>
    \\<gpx><metadata><name>Test loop</name></metadata>
    \\<trk><trkseg>
    \\<trkpt lat="45.0000" lon="6.0000"><ele>1000</ele></trkpt>
    \\<trkpt lat="45.0010" lon="6.0000"><ele>1050</ele></trkpt>
    \\<trkpt lat="45.0020" lon="6.0000"><ele>1020</ele></trkpt>
    \\</trkseg></trk></gpx>
;

test "summary_write and JSON report on a small route" {
    const allocator = std.testing.allocator;
    var data = try gpxz.parse(allocator, test_gpx, &.{});
    defer data.deinit(allocator);

    var summary: std.Io.Writer.Allocating = .init(allocator);
    defer summary.deinit();
    try summary_write(&summary.writer, &data);
    try std.testing.expect(std.mem.startsWith(u8, summary.written(), "Test loop\n"));
    try std.testing.expect(std.mem.indexOf(u8, summary.written(), "points     3\n") != null);

    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.json.Stringify.value(Report.from_data(&data), .{}, &json.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Test loop", parsed.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("point_count").?.integer);
}
