//! Stages: the intervals between consecutive stage boundaries. A thin wrapper over
//! calibration.zig, which holds the boundary resolution and physics shared by sections and
//! stages.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Trace = @import("trace.zig").Trace;
const Waypoint = @import("gpx_data.zig").Waypoint;
const pace_model = @import("pace_model.zig");
const calibration = @import("calibration.zig");

pub const StageStats = calibration.StageStats;
pub const Recalibration = calibration.Recalibration;
pub const RecalibratedETA = calibration.RecalibratedETA;

/// Returns the statistics of each stage, or null with fewer than two stage boundaries.
/// The caller owns the result.
pub fn stages_compute(
    allocator: std.mem.Allocator,
    trace: *const Trace,
    waypoints: []const Waypoint,
    settings: *const pace_model.Settings,
) !?[]StageStats {
    const stages = try calibration.intervals_compute(
        StageStats,
        .stage,
        allocator,
        trace,
        waypoints,
        settings,
    ) orelse return null;
    assert(stages.len < waypoints.len);
    return stages;
}

/// Recalibrates the remaining stages' ETAs from the runner's progress. See
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
        .stage,
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

test "stages_compute: returns null with fewer than 2 stage boundaries" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.0, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 110.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    // No stage boundaries at all
    const waypoints_none = [_]Waypoint{
        waypoint_test(0.0, 0.0, "A", null, null),
        waypoint_test(0.001, 0.0, "B", null, null),
    };
    try testing.expect((try stages_compute(allocator, &trace, &waypoints_none, &.{})) == null);

    // Only one stage boundary (Start)
    const waypoints_one = [_]Waypoint{
        waypoint_test(0.0, 0.0, "Start", "Start", null),
        waypoint_test(0.001, 0.0, "Plain", null, null),
    };
    try testing.expect((try stages_compute(allocator, &trace, &waypoints_one, &.{})) == null);
}

test "stages_compute: TimeBarrier waypoints are excluded" {
    const allocator = testing.allocator;
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 105.0 },
        [3]f64{ 0.002, 0.0, 110.0 },
        [3]f64{ 0.003, 0.0, 115.0 },
        [3]f64{ 0.004, 0.0, 120.0 },
        [3]f64{ 0.005, 0.0, 125.0 },
    };
    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    // TimeBarrier at 0.002 is a section boundary but NOT a stage boundary — should be skipped.
    // Result: 1 stage (Start→Arrival), not 2.
    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.002, 0.0, "TB1", "TimeBarrier", null),
        waypoint_test(0.005, 0.0, "Arrival", "Arrival", null),
    };

    const stages = try stages_compute(allocator, &trace, &waypoints, &.{});
    defer if (stages) |slice| allocator.free(slice);

    try testing.expect(stages != null);
    try testing.expectEqual(@as(usize, 1), stages.?.len);
    try testing.expectEqual(@as(usize, 0), stages.?[0].stage_index);
    try testing.expect(stages.?[0].distance_m > 0.0);
}

test "stages_compute: Start-LifeBase-Arrival produces two stages" {
    const allocator = testing.allocator;
    var points = try allocator.alloc([3]f64, 10);
    defer allocator.free(points);
    for (0..10) |index| {
        const fraction = @as(f64, @floatFromInt(index)) * 0.001;
        points[index] = [3]f64{ fraction, 0.0, 100.0 + fraction * 500.0 };
    }
    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.005, 0.0, "LifeBase", "LifeBase", null),
        waypoint_test(0.009, 0.0, "Arrival", "Arrival", null),
    };

    const stages = try stages_compute(allocator, &trace, &waypoints, &.{});
    defer if (stages) |slice| allocator.free(slice);

    try testing.expect(stages != null);
    try testing.expectEqual(@as(usize, 2), stages.?.len);
    // stage_index is zero-indexed and sequential
    try testing.expectEqual(@as(usize, 0), stages.?[0].stage_index);
    try testing.expectEqual(@as(usize, 1), stages.?[1].stage_index);
    // Each stage covers a non-zero distance
    try testing.expect(stages.?[0].distance_m > 0.0);
    try testing.expect(stages.?[1].distance_m > 0.0);
    // Stages are non-overlapping: first stage ends where second begins
    try testing.expect(stages.?[0].index_end <= stages.?[1].index_start);
}

test "stages_compute: loop course with coincident Start/Arrival resolves the true finish" {
    const allocator = testing.allocator;
    // A loop course: starts at (0,0), runs out to (0.01,0) and back to
    // (0.0001,0) — a finish point ~11m from the start, same as a real GPX
    // where Start/Arrival share (near-)identical coordinates.
    var points = try allocator.alloc([3]f64, 21);
    defer allocator.free(points);
    for (0..11) |index| {
        const fraction = @as(f64, @floatFromInt(index)) * 0.001;
        points[index] = [3]f64{ fraction, 0.0, 100.0 };
    }
    for (11..21) |index| {
        const fraction = @as(f64, @floatFromInt(20 - index)) * 0.001;
        points[index] = [3]f64{ fraction, 0.0, 100.0 };
    }
    points[20] = [3]f64{ 0.0001, 0.0, 100.0 };
    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    // No LifeBase — just Start and Arrival, coordinates ~11m apart.
    const waypoints = [_]Waypoint{
        waypoint_test(0.0000, 0.0, "Start", "Start", null),
        waypoint_test(0.0001, 0.0, "Arrival", "Arrival", null),
    };

    const stages = try stages_compute(allocator, &trace, &waypoints, &.{});
    defer if (stages) |slice| allocator.free(slice);

    try testing.expect(stages != null);
    try testing.expectEqual(@as(usize, 1), stages.?.len);
    // Must resolve to the end of the trace (the true finish), not a spurious
    // near-start match within the first couple of points.
    try testing.expectEqual(@as(usize, 20), stages.?[0].index_end);
    try testing.expect(stages.?[0].distance_m > 1000.0);
}

test "stage duration_s_cutoff is set from waypoint timestamps" {
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
        waypoint_test(0.003, 0.0, "End", "Arrival", 1_003_600),
    };

    const stages = try stages_compute(allocator, &trace, &waypoints, &.{});
    defer if (stages) |slice| allocator.free(slice);

    try testing.expect(stages != null);
    try testing.expectEqual(@as(usize, 1), stages.?.len);
    try testing.expect(stages.?[0].duration_s_cutoff != null);
    try testing.expectEqual(@as(i64, 3600), stages.?[0].duration_s_cutoff.?);
    try testing.expectEqual(@as(i64, 1_000_000), stages.?[0].epoch_s_start.?);
    try testing.expectEqual(@as(i64, 1_003_600), stages.?[0].epoch_s_end.?);
}

test "stage duration_s_cutoff is null when stage waypoints have no timestamps" {
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
        waypoint_test(0.003, 0.0, "End", "Arrival", null),
    };

    const stages = try stages_compute(allocator, &trace, &waypoints, &.{});
    defer if (stages) |slice| allocator.free(slice);

    try testing.expect(stages != null);
    try testing.expectEqual(@as(usize, 1), stages.?.len);
    try testing.expectEqual(@as(?i64, null), stages.?[0].duration_s_cutoff);
    try testing.expectEqual(@as(?f64, null), stages.?[0].cutoff_ratio);
}

test "stage cutoff_ratio is duration_s_estimated / duration_s_cutoff" {
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
        waypoint_test(0.000, 0.0, "Start", "Start", 1_000_000),
        waypoint_test(0.003, 0.0, "Arrival", "Arrival", 1_000_000 + 36_000),
    };

    const stages = try stages_compute(allocator, &trace, &waypoints, &.{});
    defer if (stages) |slice| allocator.free(slice);

    try testing.expect(stages != null);
    const slice = stages.?[0];
    try testing.expect(slice.cutoff_ratio != null);
    try testing.expectApproxEqAbs(
        slice.duration_s_estimated / 36_000.0,
        slice.cutoff_ratio.?,
        1e-9,
    );
    try testing.expect(slice.cutoff_ratio.? < 1.0);
}

// recalibrate (stage wrapper).
// The calibration physics are covered in calibration.zig. These integration
// tests verify the stage-granularity wrapper: it splits on Start/LifeBase/Arrival
// (ignoring TimeBarriers) and agrees with the a-priori stage model.

test "recalibrate: stage wrapper at the start reproduces the a-priori stage total" {
    const allocator = testing.allocator;
    var points = try allocator.alloc([3]f64, 30);
    defer allocator.free(points);
    for (0..30) |index| {
        points[index] = [3]f64{ @as(f64, @floatFromInt(index)) * 0.001, 0.0, 100.0 };
    }
    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    // Start(idx0) / TB1(idx5) / LB1(idx10) / LB2(idx20) / Arrival(idx29).
    // As stages the TimeBarrier is ignored -> 3 stages.
    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.005, 0.0, "TB1", "TimeBarrier", null),
        waypoint_test(0.010, 0.0, "LB1", "LifeBase", null),
        waypoint_test(0.020, 0.0, "LB2", "LifeBase", null),
        waypoint_test(0.029, 0.0, "Arrival", "Arrival", null),
    };

    const predicted = try stages_compute(allocator, &trace, &waypoints, &settings_no_stop);
    defer if (predicted) |slice| allocator.free(slice);
    try testing.expect(predicted != null);
    try testing.expectEqual(@as(usize, 3), predicted.?.len);
    var predicted_total_s: f64 = 0.0;
    for (predicted.?) |slice| predicted_total_s += slice.duration_s_estimated;

    var result = try recalibrate(allocator, &trace, &waypoints, 0, 0.0, &settings_no_stop);
    defer if (result) |*recalibration| recalibration.deinit(allocator);
    try testing.expect(result != null);
    const recalibration = result.?;

    try testing.expectEqual(@as(f64, 1.0), recalibration.calibration_factor);
    try testing.expectEqual(@as(usize, 3), recalibration.etas.len); // TimeBarrier ignored
    for (recalibration.etas, 0..) |eta, index| {
        const expected_s = predicted.?[index].duration_s_estimated;
        try testing.expectApproxEqAbs(expected_s, eta.duration_s_remaining, 1e-6);
    }
    const total_s = recalibration.etas[recalibration.etas.len - 1].duration_s_remaining_cumulative;
    try testing.expectApproxEqAbs(predicted_total_s, total_s, 1e-6);
}

test "recalibrate: stage wrapper solves a factor and zeroes completed stages" {
    const allocator = testing.allocator;
    var points = try allocator.alloc([3]f64, 30);
    defer allocator.free(points);
    for (0..30) |index| {
        points[index] = [3]f64{ @as(f64, @floatFromInt(index)) * 0.001, 0.0, 100.0 };
    }
    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.010, 0.0, "LB1", "LifeBase", null),
        waypoint_test(0.020, 0.0, "LB2", "LifeBase", null),
        waypoint_test(0.029, 0.0, "Arrival", "Arrival", null),
    };

    // Runner reached LB1 (idx 10, end of stage 0) slower than predicted.
    var result = try recalibrate(allocator, &trace, &waypoints, 10, 900.0, &settings_no_stop);
    defer if (result) |*recalibration| recalibration.deinit(allocator);
    try testing.expect(result != null);
    const recalibration = result.?;

    try testing.expectEqual(@as(usize, 3), recalibration.etas.len);
    try testing.expect(recalibration.calibration_factor > 1.0);
    try testing.expectEqual(@as(f64, 0.0), recalibration.etas[0].duration_s_remaining);
    try testing.expect(recalibration.etas[1].duration_s_remaining > 0.0);
    const cumulative_1 = recalibration.etas[1].duration_s_remaining_cumulative;
    try testing.expect(recalibration.etas[2].duration_s_remaining_cumulative > cumulative_1);
}
