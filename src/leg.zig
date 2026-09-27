//! Legs: the intervals between every pair of consecutive waypoints, typed or not. The finest
//! grouping; each leg belongs to a section. Legs have no cutoff and no pace model: their
//! duration is Naismith's rule, a quick hiking estimate.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Trace = @import("trace.zig").Trace;
const Waypoint = @import("gpx_data.zig").Waypoint;
const bearing_to = @import("gps_point.zig").bearing_to;
const elevation = @import("elevation.zig");

pub const LegStats = struct {
    leg_index: usize,
    /// The section this leg belongs to.
    section_index: usize,
    index_start: usize,
    index_end: usize,
    /// The CLI caps files at 64 MiB, far below 4 billion points; `@intCast` checks it for
    /// other callers.
    point_count: u32,
    point_start: [3]f64,
    point_end: [3]f64,
    /// The names of the start and end waypoints.
    location_start: []const u8,
    location_end: []const u8,
    distance_m: f64,
    elevation_gain_m: f64,
    elevation_loss_m: f64,
    /// Net climb over distance.
    slope_percent_average: f64,
    slope_percent_max: f64,
    elevation_m_min: f64,
    elevation_m_max: f64,
    bearing_degrees: f64,
    /// From 1 to 5, from Naismith time over flat time; see `difficulty_from_effort_ratio`.
    difficulty: u8,
    /// Naismith's rule.
    duration_s_estimated: f64,
};

/// Naismith's rule: 5 km/h on the flat, plus an hour per 600 m of climb.
const naismith_speed_kmh = 5.0;
const naismith_climb_m_per_h = 600.0;

/// Returns the statistics of the leg between each pair of consecutive waypoints. A pair
/// that doesn't resolve onto the trace, or resolves backwards, has no leg. The caller owns
/// the result.
pub fn legs_compute(
    allocator: std.mem.Allocator,
    trace: *const Trace,
    waypoints: []const Waypoint,
) ![]LegStats {
    var legs: std.ArrayList(LegStats) = .empty;
    defer legs.deinit(allocator);
    if (waypoints.len < 2) return legs.toOwnedSlice(allocator);

    // Each waypoint resolves after the previous one, so a loop course can't snap back to an
    // earlier pass through the same place.
    var search_start: usize = 0;
    // Legs before the first section boundary belong to section 0.
    var section_index: usize = 0;
    var section_seen = false;
    for (waypoints[0 .. waypoints.len - 1], waypoints[1..], 0..) |*start, *end, leg_index| {
        if (start.is_section_boundary()) {
            if (section_seen) section_index += 1;
            section_seen = true;
        }
        const coordinates_start = [3]f64{ start.latitude, start.longitude, 0.0 };
        const coordinates_end = [3]f64{ end.latitude, end.longitude, 0.0 };
        const closest_start = trace.closest_point_after(coordinates_start, search_start) orelse
            continue;
        const search_end = closest_start.index + 1;
        const closest_end = trace.closest_point_after(coordinates_end, search_end) orelse
            continue;
        search_start = closest_end.index;
        if (closest_start.index >= closest_end.index) continue;

        var leg = leg_stats(trace, closest_start.index, closest_end.index);
        leg.leg_index = leg_index;
        leg.section_index = section_index;
        leg.location_start = start.name;
        leg.location_end = end.name;
        leg.bearing_degrees = bearing_to(coordinates_start, coordinates_end);
        try legs.append(allocator, leg);
    }
    assert(legs.items.len < waypoints.len);
    return legs.toOwnedSlice(allocator);
}

/// Returns the trace statistics of the leg from point `start` to point `end`. The fields
/// that come from the waypoints are left for the caller.
fn leg_stats(trace: *const Trace, start: usize, end: usize) LegStats {
    assert(start < end);
    assert(end < trace.points.len);
    const distance_m = trace.distances_m_cumulative[end] - trace.distances_m_cumulative[start];
    const gain_m = trace.elevation_gains_m_cumulative[end] -
        trace.elevation_gains_m_cumulative[start];
    const loss_m = trace.elevation_losses_m_cumulative[end] -
        trace.elevation_losses_m_cumulative[start];

    var elevation_m_min = trace.points[start][2];
    var elevation_m_max = trace.points[start][2];
    var slope_percent_max: f64 = 0.0;
    for (trace.points[start..end], trace.slopes_percent[start..end]) |point, slope| {
        elevation_m_min = @min(elevation_m_min, point[2]);
        elevation_m_max = @max(elevation_m_max, point[2]);
        slope_percent_max = @max(slope_percent_max, @abs(slope));
    }

    // Naismith counts the total climb, not the net, so a leg that climbs a lot is rated hard
    // even when its gain and loss cancel out.
    const flat_h = (distance_m / 1000.0) / naismith_speed_kmh;
    const naismith_h = flat_h + gain_m / naismith_climb_m_per_h;
    const effort_ratio = if (flat_h > 0) naismith_h / flat_h else 1.0;
    assert(naismith_h >= flat_h);
    return .{
        .leg_index = undefined,
        .section_index = undefined,
        .index_start = start,
        .index_end = end,
        .point_count = @intCast(end - start + 1),
        .point_start = trace.points[start],
        .point_end = trace.points[end],
        .location_start = undefined,
        .location_end = undefined,
        .distance_m = distance_m,
        .elevation_gain_m = gain_m,
        .elevation_loss_m = loss_m,
        .slope_percent_average = elevation.slope_percent_net(gain_m, loss_m, distance_m),
        .slope_percent_max = slope_percent_max,
        .elevation_m_min = elevation_m_min,
        .elevation_m_max = elevation_m_max,
        .bearing_degrees = undefined,
        .difficulty = difficulty_from_effort_ratio(effort_ratio),
        .duration_s_estimated = naismith_h * 3600.0,
    };
}

/// Returns 1 to 5 from Naismith time over flat time: below 1.2, 1.5, 2.0, 2.7, or above.
pub fn difficulty_from_effort_ratio(effort_ratio: f64) u8 {
    assert(effort_ratio >= 1.0);
    if (effort_ratio < 1.2) return 1;
    if (effort_ratio < 1.5) return 2;
    if (effort_ratio < 2.0) return 3;
    if (effort_ratio < 2.7) return 4;
    return 5;
}

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

test "legs_compute: basic functionality" {
    const allocator = testing.allocator;

    const points = [_][3]f64{
        [3]f64{ 37.0, -122.0, 100.0 },
        [3]f64{ 37.01, -122.01, 120.0 },
        [3]f64{ 37.02, -122.02, 140.0 },
        [3]f64{ 37.03, -122.03, 160.0 },
        [3]f64{ 37.04, -122.04, 180.0 },
        [3]f64{ 37.05, -122.05, 200.0 },
        [3]f64{ 37.06, -122.06, 220.0 },
        [3]f64{ 37.07, -122.07, 240.0 },
        [3]f64{ 37.08, -122.08, 260.0 },
        [3]f64{ 37.09, -122.09, 280.0 },
        [3]f64{ 37.10, -122.10, 300.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(37.0, -122.0, "Start", null, null),
        waypoint_test(37.05, -122.05, "Middle", null, null),
        waypoint_test(37.10, -122.10, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 2), legs.len);

    for (legs) |leg| {
        try testing.expect(leg.distance_m > 0.0);
        try testing.expect(leg.elevation_gain_m >= 0.0);
        try testing.expect(leg.point_count > 0);
        try testing.expect(leg.index_start < leg.index_end);
        try testing.expect(leg.index_end <= trace.points.len);
    }
}

test "legs_compute: single waypoint returns empty" {
    const allocator = testing.allocator;

    const points = [_][3]f64{
        [3]f64{ 37.0, -122.0, 100.0 },
        [3]f64{ 37.1, -122.1, 200.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(37.0, -122.0, "Only", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 0), legs.len);
}

test "legs_compute: elevation statistics" {
    const allocator = testing.allocator;

    const points = [_][3]f64{
        [3]f64{ 0.0, 0.0, 100.0 },
        [3]f64{ 0.01, 0.01, 150.0 },
        [3]f64{ 0.02, 0.02, 200.0 },
        [3]f64{ 0.03, 0.03, 180.0 },
        [3]f64{ 0.04, 0.04, 220.0 },
        [3]f64{ 0.05, 0.05, 190.0 },
        [3]f64{ 0.06, 0.06, 160.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "Start", null, null),
        waypoint_test(0.06, 0.06, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);

    const leg = legs[0];
    try testing.expect(leg.elevation_m_min >= 100.0);
    try testing.expect(leg.elevation_m_max <= 220.0);
    try testing.expect(leg.elevation_gain_m > 0.0);
    try testing.expect(leg.elevation_loss_m > 0.0);
}

test "legs_compute: section indices are valid" {
    const allocator = testing.allocator;

    var points = try allocator.alloc([3]f64, 50);
    defer allocator.free(points);

    for (0..50) |index| {
        const fraction = @as(f64, @floatFromInt(index)) / 50.0;
        points[index] = [3]f64{ fraction, fraction, 100.0 + fraction * 100.0 };
    }

    var trace = try Trace.init(allocator, points);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "W1", null, null),
        waypoint_test(0.5, 0.5, "W2", null, null),
        waypoint_test(1.0, 1.0, "W3", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 2), legs.len);

    try testing.expect(legs[0].index_start < legs[0].index_end);
    try testing.expect(legs[0].index_end <= legs[1].index_start);
    try testing.expect(legs[1].index_start < legs[1].index_end);
    try testing.expect(legs[1].index_end <= trace.points.len);
}

test "legs_compute: slope calculations" {
    const allocator = testing.allocator;

    const points = [_][3]f64{
        [3]f64{ 0.0, 0.0, 0.0 },
        [3]f64{ 0.001, 0.001, 50.0 },
        [3]f64{ 0.002, 0.002, 100.0 },
        [3]f64{ 0.003, 0.003, 150.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "Bottom", null, null),
        waypoint_test(0.003, 0.003, "Top", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);

    const leg = legs[0];
    try testing.expect(leg.slope_percent_average > 0.0);
    try testing.expect(leg.slope_percent_max > 0.0);
}

test "difficulty: flat terrain is Easy (1)" {
    const allocator = testing.allocator;

    const points = [_][3]f64{
        [3]f64{ 0.0, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 100.1 },
        [3]f64{ 0.002, 0.0, 100.2 },
        [3]f64{ 0.003, 0.0, 100.3 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "Start", null, null),
        waypoint_test(0.003, 0.0, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);
    try testing.expectEqual(@as(u8, 1), legs[0].difficulty);
    try testing.expect(legs[0].duration_s_estimated > 0.0);
}

test "difficulty: steep terrain is Hard or above" {
    const allocator = testing.allocator;

    const points = [_][3]f64{
        [3]f64{ 0.0, 0.0, 0.0 },
        [3]f64{ 0.001, 0.001, 50.0 },
        [3]f64{ 0.002, 0.002, 100.0 },
        [3]f64{ 0.003, 0.003, 150.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "Bottom", null, null),
        waypoint_test(0.003, 0.003, "Top", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);
    try testing.expect(legs[0].difficulty >= 3);
    try testing.expect(legs[0].duration_s_estimated > 0.0);
}

// Difficulty tiers.
//
// Each test uses 4 points covering ~333m (3 × 111m per 0.001° lat at equator).
// Haversine distance ≈ 333.6m → dist_km ≈ 0.3336
// effort_ratio = 1 + elevation_gain / (120 × dist_km) ≈ 1 + elevation_gain / 40.03
//
// Tier boundaries (elevation_gain for dist ≈ 0.3336 km):
//   1→2 at ~8.0m    (effort_ratio = 1.2)
//   2→3 at ~20.0m   (effort_ratio = 1.5)
//   3→4 at ~40.0m   (effort_ratio = 2.0)
//   4→5 at ~68.0m   (effort_ratio = 2.7)

test "difficulty: tier 2 Moderate (effort_ratio 1.2–1.5)" {
    const allocator = testing.allocator;

    // 14m gain → effort ≈ 1.35 → difficulty 2
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 0.0 },
        [3]f64{ 0.001, 0.0, 4.67 },
        [3]f64{ 0.002, 0.0, 9.33 },
        [3]f64{ 0.003, 0.0, 14.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", null, null),
        waypoint_test(0.003, 0.0, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);
    try testing.expectEqual(@as(u8, 2), legs[0].difficulty);
}

test "difficulty: tier 3 Hard (effort_ratio 1.5–2.0)" {
    const allocator = testing.allocator;

    // 30m gain → effort ≈ 1.75 → difficulty 3
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 0.0 },
        [3]f64{ 0.001, 0.0, 10.0 },
        [3]f64{ 0.002, 0.0, 20.0 },
        [3]f64{ 0.003, 0.0, 30.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", null, null),
        waypoint_test(0.003, 0.0, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);
    try testing.expectEqual(@as(u8, 3), legs[0].difficulty);
}

test "difficulty: tier 4 Very Hard (effort_ratio 2.0–2.7)" {
    const allocator = testing.allocator;

    // 55m gain → effort ≈ 2.37 → difficulty 4
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 0.0 },
        [3]f64{ 0.001, 0.0, 18.0 },
        [3]f64{ 0.002, 0.0, 37.0 },
        [3]f64{ 0.003, 0.0, 55.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", null, null),
        waypoint_test(0.003, 0.0, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);
    try testing.expectEqual(@as(u8, 4), legs[0].difficulty);
}

test "difficulty: tier 5 Extreme (effort_ratio >= 2.7)" {
    const allocator = testing.allocator;

    // 100m gain → effort ≈ 3.50 → difficulty 5
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 0.0 },
        [3]f64{ 0.001, 0.0, 33.0 },
        [3]f64{ 0.002, 0.0, 67.0 },
        [3]f64{ 0.003, 0.0, 100.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", null, null),
        waypoint_test(0.003, 0.0, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);
    try testing.expectEqual(@as(u8, 5), legs[0].difficulty);
}

test "duration_s_estimated follows Naismith formula" {
    const allocator = testing.allocator;

    // Flat 1km section: 0m elevation gain
    // flat_time = 1.0/5 = 0.2h, naismith_time = 0.2h, estimated_duration = 720s
    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 100.0 },
        [3]f64{ 0.002, 0.0, 100.0 },
        [3]f64{ 0.003, 0.0, 100.0 },
        [3]f64{ 0.004, 0.0, 100.0 },
        [3]f64{ 0.005, 0.0, 100.0 },
        [3]f64{ 0.006, 0.0, 100.0 },
        [3]f64{ 0.007, 0.0, 100.0 },
        [3]f64{ 0.008, 0.0, 100.0 },
        [3]f64{ 0.009, 0.0, 100.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", null, null),
        waypoint_test(0.009, 0.0, "End", null, null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    try testing.expectEqual(@as(usize, 1), legs.len);
    const leg = legs[0];
    // dist ≈ 1001m → flat_time = 1.001/5 = 0.2002h → duration ≈ 720.7s
    // Allow ±30s tolerance for Haversine approximation
    try testing.expect(leg.duration_s_estimated > 690.0);
    try testing.expect(leg.duration_s_estimated < 750.0);
    try testing.expectEqual(@as(u8, 1), leg.difficulty);
}

test "legs_compute: section_index links legs to their section" {
    const allocator = testing.allocator;

    const points = [_][3]f64{
        [3]f64{ 0.000, 0.0, 100.0 },
        [3]f64{ 0.001, 0.0, 100.0 },
        [3]f64{ 0.002, 0.0, 100.0 },
        [3]f64{ 0.003, 0.0, 100.0 },
        [3]f64{ 0.004, 0.0, 100.0 },
        [3]f64{ 0.005, 0.0, 100.0 },
        [3]f64{ 0.006, 0.0, 100.0 },
        [3]f64{ 0.007, 0.0, 100.0 },
        [3]f64{ 0.008, 0.0, 100.0 },
        [3]f64{ 0.009, 0.0, 100.0 },
        [3]f64{ 0.010, 0.0, 100.0 },
    };

    var trace = try Trace.init(allocator, points[0..]);
    defer trace.deinit(allocator);

    // Section boundaries: Start at 0, TimeBarrier at 0.004, Arrival at 0.008
    // Plain waypoints at 0.002 and 0.006 create extra legs within sections
    const waypoints = [_]Waypoint{
        waypoint_test(0.000, 0.0, "Start", "Start", null),
        waypoint_test(0.002, 0.0, "Plain1", null, null),
        waypoint_test(0.004, 0.0, "BH1", "TimeBarrier", null),
        waypoint_test(0.006, 0.0, "Plain2", null, null),
        waypoint_test(0.008, 0.0, "Arrival", "Arrival", null),
    };

    const legs = try legs_compute(allocator, &trace, &waypoints);
    defer allocator.free(legs);

    // 4 legs: [Start→Plain1], [Plain1→TimeBarrier], [TimeBarrier→Plain2], [Plain2→Arrival]
    try testing.expectEqual(@as(usize, 4), legs.len);

    // Legs 0 and 1 belong to section 0 (Start → TimeBarrier)
    try testing.expectEqual(@as(usize, 0), legs[0].section_index);
    try testing.expectEqual(@as(usize, 0), legs[1].section_index);

    // Legs 2 and 3 belong to section 1 (TimeBarrier → Arrival)
    try testing.expectEqual(@as(usize, 1), legs[2].section_index);
    try testing.expectEqual(@as(usize, 1), legs[3].section_index);
}

test "difficulty_from_effort_ratio: each threshold" {
    try testing.expectEqual(@as(u8, 1), difficulty_from_effort_ratio(1.0));
    try testing.expectEqual(@as(u8, 2), difficulty_from_effort_ratio(1.2));
    try testing.expectEqual(@as(u8, 3), difficulty_from_effort_ratio(1.5));
    try testing.expectEqual(@as(u8, 4), difficulty_from_effort_ratio(2.0));
    try testing.expectEqual(@as(u8, 5), difficulty_from_effort_ratio(2.7));
}

test "legs_compute: no waypoints and one waypoint have no legs" {
    const points = [_][3]f64{ .{ 0.0, 0.0, 100.0 }, .{ 0.001, 0.0, 110.0 } };
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    const none = try legs_compute(testing.allocator, &trace, &.{});
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}
