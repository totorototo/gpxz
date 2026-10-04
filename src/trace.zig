//! A trace: the track points of a route, with per-point arrays (cumulative distance, D+ and
//! D-, slope, pace factor) and the peaks, valleys, climbs and descents of its elevation
//! profile.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const distance = @import("gps_point.zig").distance;
const extrema = @import("extrema.zig");
const climbs_detect = @import("climbs.zig").climbs_detect;
const descents_detect = @import("climbs.zig").descents_detect;
pub const ClimbStats = @import("climbs.zig").ClimbStats;
pub const DescentStats = @import("climbs.zig").DescentStats;
const douglas_peucker_indices = @import("simplify.zig").douglas_peucker_indices;
const elevation = @import("elevation.zig");
const minetti = @import("minetti.zig");

/// Longer traces are simplified with Douglas-Peucker, which keeps rendering and per-point
/// math cheap; D+/D- still come from every point.
const simplify_points_min = 1000;
const simplify_epsilon_m = 2.0;

/// A nearest-point search locks onto a candidate this close...
const lock_in_distance_m = 1000.0;
/// ...and stops once the trace is this much farther away than it.
const early_stop_margin_m = 2000.0;

pub const ClosestPoint = struct {
    point: [3]f64,
    index: usize,
    distance_m: f64,
};

pub const Trace = struct {
    points: [][3]f64,
    /// The same memory as `points` seen as a flat [lat, lon, ele, ...] slice: [3]f64 has no
    /// padding, so this is an alias, not a copy. JavaScript reads it as one Float64Array
    /// through Zigar instead of paying a proxy trap per point. `deinit` frees `points` only.
    points_flat: []f64,
    /// From the first point, along the path.
    distances_m_cumulative: []f64,
    /// Denoised, from every point of the source even when `points` is simplified.
    elevation_gains_m_cumulative: []f64,
    elevation_losses_m_cumulative: []f64,
    /// Smoothed grade at each point; see `elevation.slopes_compute`.
    slopes_percent: []f64,
    /// The Minetti pace factor for each slope.
    pace_factors: []f64,
    /// Indices of the peaks and valleys of the elevation profile, ascending.
    peaks: []usize,
    valleys: []usize,
    climbs: []ClimbStats,
    descents: []DescentStats,
    distance_m: f64,
    elevation_gain_m: f64,
    elevation_loss_m: f64,

    /// Builds the trace of `coordinates`. It copies them: the caller keeps ownership.
    pub fn init(allocator: std.mem.Allocator, coordinates: []const [3]f64) !Trace {
        const simplified = try points_simplify(allocator, coordinates);
        const points = simplified.points;
        errdefer allocator.free(points);
        defer allocator.free(simplified.source_indices);
        assert(points.len == simplified.source_indices.len);

        const distances_m = try elevation.distances_cumulative(allocator, points);
        errdefer allocator.free(distances_m);
        var gain_loss = try elevation.gain_loss_compute(
            allocator,
            coordinates,
            elevation.median_radius_m,
            elevation.noise_threshold_m,
        );
        defer gain_loss.deinit(allocator);
        // Each kept point takes the cumulative D+/D- of its source point, so the totals are
        // those of the full-resolution signal, not of the simplified one.
        const gains_m = try allocator.alloc(f64, points.len);
        errdefer allocator.free(gains_m);
        const losses_m = try allocator.alloc(f64, points.len);
        errdefer allocator.free(losses_m);
        for (simplified.source_indices, gains_m, losses_m) |source, *gain_m, *loss_m| {
            gain_m.* = gain_loss.gains_m_cumulative[source];
            loss_m.* = gain_loss.losses_m_cumulative[source];
        }

        const slopes = try elevation.slopes_compute(allocator, points, distances_m);
        errdefer allocator.free(slopes);
        const pace_factors = try allocator.alloc(f64, slopes.len);
        errdefer allocator.free(pace_factors);
        for (slopes, pace_factors) |slope, *factor| factor.* = minetti.pace_factor(slope / 100.0);

        const profile = try profile_analyze(allocator, points, distances_m);
        const trace: Trace = .{
            .points = points,
            .points_flat = @as([*]f64, @ptrCast(points.ptr))[0 .. points.len * 3],
            .distances_m_cumulative = distances_m,
            .elevation_gains_m_cumulative = gains_m,
            .elevation_losses_m_cumulative = losses_m,
            .slopes_percent = slopes,
            .pace_factors = pace_factors,
            .peaks = profile.peaks,
            .valleys = profile.valleys,
            .climbs = profile.climbs,
            .descents = profile.descents,
            .distance_m = if (points.len > 0) distances_m[points.len - 1] else 0.0,
            .elevation_gain_m = gain_loss.gain_m_total,
            .elevation_loss_m = gain_loss.loss_m_total,
        };
        trace.assert_valid();
        return trace;
    }

    pub fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.distances_m_cumulative);
        allocator.free(self.elevation_gains_m_cumulative);
        allocator.free(self.elevation_losses_m_cumulative);
        allocator.free(self.slopes_percent);
        allocator.free(self.pace_factors);
        allocator.free(self.peaks);
        allocator.free(self.valleys);
        allocator.free(self.climbs);
        allocator.free(self.descents);
        self.* = undefined;
    }

    fn assert_valid(self: *const Trace) void {
        const count = self.points.len;
        assert(self.points_flat.len == count * 3);
        assert(self.distances_m_cumulative.len == count);
        assert(self.elevation_gains_m_cumulative.len == count);
        assert(self.elevation_losses_m_cumulative.len == count);
        assert(self.slopes_percent.len == count);
        assert(self.pace_factors.len == count);
        assert(self.peaks.len <= count and self.valleys.len <= count);
        assert(self.distance_m >= 0);
        assert(self.elevation_gain_m >= 0 and self.elevation_loss_m >= 0);
    }

    /// Returns the first point at least `distance_m` along the trace, or the last point past
    /// the end. Null for a negative distance or an empty trace.
    pub fn point_at_distance(self: *const Trace, distance_m: f64) ?[3]f64 {
        if (distance_m < 0 or self.points.len == 0) return null;
        return self.points[self.index_at_distance(distance_m)];
    }

    /// Returns the index of the first point at least `distance_m` along the trace, or the last
    /// index past the end. 0 for an empty trace.
    pub fn index_at_distance(self: *const Trace, distance_m: f64) usize {
        if (self.points.len == 0) return 0;
        const index = std.sort.partitionPoint(f64, self.distances_m_cumulative, distance_m, less);
        const result = @min(index, self.points.len - 1);
        assert(result < self.points.len);
        return result;
    }

    fn less(target: f64, value: f64) bool {
        return value < target;
    }

    /// Returns the points from `start_m` to `end_m` along the trace, both included, as a
    /// slice of `points`. Null for an empty trace, a negative distance or `start_m > end_m`.
    pub fn slice_between_distances(self: *const Trace, start_m: f64, end_m: f64) ?[][3]f64 {
        if (self.points.len == 0) return null;
        if (start_m < 0 or end_m < 0 or start_m > end_m) return null;
        const index_start = self.index_at_distance(start_m);
        const index_end = self.index_at_distance(end_m);
        assert(index_start <= index_end);
        return self.points[index_start .. index_end + 1];
    }

    pub fn closest_point(self: *const Trace, target: [3]f64) ?ClosestPoint {
        return self.closest_point_after(target, 0);
    }

    /// Returns the point nearest `target` (in 2D) at or after index `start`. Once a candidate
    /// within `lock_in_distance_m` is found, the scan stops when the trace is
    /// `early_stop_margin_m` farther than it. So on a loop course the first close pass wins,
    /// not a later one that happens to be marginally closer.
    pub fn closest_point_after(self: *const Trace, target: [3]f64, start: usize) ?ClosestPoint {
        if (start >= self.points.len) return null;
        var closest: ClosestPoint = .{
            .point = self.points[start],
            .index = start,
            .distance_m = std.math.inf(f64),
        };
        for (self.points[start..], start..) |point, index| {
            const distance_m = distance(target, point);
            if (distance_m < closest.distance_m) {
                closest = .{ .point = point, .index = index, .distance_m = distance_m };
            } else if (closest.distance_m < lock_in_distance_m and
                distance_m > closest.distance_m + early_stop_margin_m)
            {
                break;
            }
        }
        assert(closest.index >= start and closest.index < self.points.len);
        assert(std.math.isFinite(closest.distance_m));
        return closest;
    }
};

const Simplified = struct {
    points: [][3]f64,
    /// The index in the source of each kept point.
    source_indices: []usize,
};

/// Returns a copy of `coordinates`, simplified when there are more than
/// `simplify_points_min`, with each kept point's source index. The caller owns both.
fn points_simplify(allocator: std.mem.Allocator, coordinates: []const [3]f64) !Simplified {
    const source_indices = if (coordinates.len > simplify_points_min)
        try douglas_peucker_indices(allocator, coordinates, simplify_epsilon_m)
    else identity: {
        const indices = try allocator.alloc(usize, coordinates.len);
        for (indices, 0..) |*index, position| index.* = position;
        break :identity indices;
    };
    errdefer allocator.free(source_indices);

    const points = try allocator.alloc([3]f64, source_indices.len);
    for (points, source_indices) |*point, source| point.* = coordinates[source];
    assert(points.len <= coordinates.len);
    return .{ .points = points, .source_indices = source_indices };
}

const Profile = struct {
    peaks: []usize,
    valleys: []usize,
    climbs: []ClimbStats,
    descents: []DescentStats,
};

/// Returns the peaks, valleys, climbs and descents of the elevation profile. The caller owns
/// them.
fn profile_analyze(
    allocator: std.mem.Allocator,
    points: []const [3]f64,
    distances_m: []const f64,
) !Profile {
    assert(points.len == distances_m.len);
    const elevations_m = try allocator.alloc(f32, points.len);
    defer allocator.free(elevations_m);
    for (points, elevations_m) |point, *elevation_m| elevation_m.* = @floatCast(point[2]);

    const peaks = try extrema.find_peaks(allocator, elevations_m);
    errdefer allocator.free(peaks);
    const valleys = try extrema.find_valleys(allocator, elevations_m);
    errdefer allocator.free(valleys);
    const climbs = try climbs_detect(allocator, peaks, valleys, points, distances_m);
    errdefer allocator.free(climbs);
    const descents = try descents_detect(allocator, peaks, valleys, points, distances_m);
    return .{ .peaks = peaks, .valleys = valleys, .climbs = climbs, .descents = descents };
}

/// Four points about 111 m apart due east along the equator.
const line_points = [_][3]f64{
    .{ 0.0, 0.000, 100.0 },
    .{ 0.0, 0.001, 105.0 },
    .{ 0.0, 0.002, 110.0 },
    .{ 0.0, 0.003, 115.0 },
};

test "init: 0 and 1 points" {
    var empty = try Trace.init(testing.allocator, &.{});
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.points.len);
    try testing.expectEqual(@as(usize, 0), empty.slopes_percent.len);
    try testing.expectEqual(@as(f64, 0), empty.distance_m);
    try testing.expectEqual(@as(f64, 0), empty.elevation_gain_m);

    const one = [_][3]f64{.{ 45.0, 6.0, 1000.0 }};
    var single = try Trace.init(testing.allocator, &one);
    defer single.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), single.points.len);
    try testing.expectEqual(@as(f64, 0), single.distance_m);
    try testing.expectEqual(@as(f64, 0), single.slopes_percent[0]);
    try testing.expectEqual(@as(usize, 0), single.peaks.len);
}

test "init: copies the points, and the flat alias matches them" {
    var trace = try Trace.init(testing.allocator, &line_points);
    defer trace.deinit(testing.allocator);
    try testing.expectEqualSlices([3]f64, &line_points, trace.points);
    try testing.expect(trace.points.ptr != &line_points);
    for (trace.points, 0..) |point, index| {
        try testing.expectEqualSlices(f64, &point, trace.points_flat[index * 3 ..][0..3]);
    }
    try testing.expectApproxEqAbs(333.6, trace.distance_m, 0.5);
}

test "init: the cumulative arrays start at 0, never decrease, and end at the totals" {
    const points = [_][3]f64{
        .{ 0.0, 0.000, 100.0 },
        .{ 0.0, 0.001, 105.0 },
        .{ 0.0, 0.002, 110.0 },
        .{ 0.0, 0.003, 90.0 },
        .{ 0.0, 0.004, 112.0 },
    };
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    const arrays = [_][]const f64{
        trace.distances_m_cumulative,
        trace.elevation_gains_m_cumulative,
        trace.elevation_losses_m_cumulative,
    };
    const totals = [_]f64{ trace.distance_m, trace.elevation_gain_m, trace.elevation_loss_m };
    for (arrays, totals) |array, total| {
        try testing.expectEqual(@as(f64, 0), array[0]);
        for (array[1..], array[0 .. array.len - 1]) |value, previous| {
            try testing.expect(value >= previous);
        }
        try testing.expectEqual(total, array[array.len - 1]);
    }
}

test "init: pace factors follow the slopes, and flat is 1" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 0.0, 0.001, 100.0 },
        .{ 0.0, 0.002, 100.0 },
    };
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(trace.slopes_percent.len, trace.pace_factors.len);
    for (trace.pace_factors) |factor| try testing.expectEqual(@as(f64, 1.0), factor);
}

test "init: noisy climb slopes stay near the true grade" {
    // About +5 m per 111 m with alternating 1 m steps: 4.5% on average.
    const points = [_][3]f64{
        .{ 0.0, 0.000, 100.0 },
        .{ 0.0, 0.001, 105.0 },
        .{ 0.0, 0.002, 106.0 },
        .{ 0.0, 0.003, 111.0 },
        .{ 0.0, 0.004, 112.0 },
        .{ 0.0, 0.005, 117.0 },
    };
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    var sum: f64 = 0.0;
    for (trace.slopes_percent[1..]) |slope| {
        try testing.expect(slope >= -5.0 and slope <= 10.0);
        sum += slope;
    }
    const mean = sum / @as(f64, @floatFromInt(trace.slopes_percent.len - 1));
    try testing.expect(mean >= 2.0 and mean <= 7.0);
}

test "init: more than 1000 points are simplified, and D+ keeps every point" {
    var points: [1500][3]f64 = undefined;
    for (&points, 0..) |*point, index| {
        const t = @as(f64, @floatFromInt(index)) / 1500.0;
        point.* = .{ 45.0 + t * 0.1, 6.0 + t * 0.1 + @sin(t * 20.0) * 0.001, 100.0 + t * 500.0 };
    }
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    try testing.expect(trace.points.len < points.len);
    try testing.expectEqual(points[0], trace.points[0]);
    try testing.expectEqual(points[points.len - 1], trace.points[trace.points.len - 1]);
    // A steady 500 m climb: the denoised gain undercounts by at most the deadband.
    try testing.expect(trace.elevation_gain_m > 500.0 - elevation.noise_threshold_m);
    try testing.expect(trace.elevation_gain_m <= 500.0);

    // At exactly 1000 points nothing is simplified.
    var exact = try Trace.init(testing.allocator, points[0..simplify_points_min]);
    defer exact.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, simplify_points_min), exact.points.len);
}

test "init: peaks and valleys are sorted and in bounds" {
    var points: [120][3]f64 = undefined;
    for (&points, 0..) |*point, index| {
        const x: f64 = @floatFromInt(index);
        point.* = .{ 45.0, 6.0 + x * 0.001, 1000.0 + 300.0 * @sin(x / 12.0) };
    }
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    try testing.expect(trace.peaks.len > 0 and trace.valleys.len > 0);
    for ([_][]const usize{ trace.peaks, trace.valleys }) |indices| {
        try testing.expect(std.sort.isSorted(usize, indices, {}, std.sort.asc(usize)));
        for (indices) |index| try testing.expect(index < trace.points.len);
    }
}

test "index_at_distance: exact, between, and past the end" {
    var trace = try Trace.init(testing.allocator, &line_points);
    defer trace.deinit(testing.allocator);
    const distances_m = trace.distances_m_cumulative;
    for (distances_m, 0..) |distance_m, index| {
        try testing.expectEqual(index, trace.index_at_distance(distance_m));
    }
    try testing.expectEqual(@as(usize, 1), trace.index_at_distance(distances_m[1] / 2));
    try testing.expectEqual(@as(usize, 3), trace.index_at_distance(1e9));
    try testing.expectEqual(@as(usize, 0), trace.index_at_distance(-5.0));
}

test "point_at_distance: in meters, null before the start, the last point after the end" {
    var trace = try Trace.init(testing.allocator, &line_points);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(line_points[0], trace.point_at_distance(0.0).?);
    try testing.expectEqual(line_points[1], trace.point_at_distance(100.0).?);
    try testing.expectEqual(line_points[3], trace.point_at_distance(10_000.0).?);
    try testing.expectEqual(@as(?[3]f64, null), trace.point_at_distance(-1.0));

    var empty = try Trace.init(testing.allocator, &.{});
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(?[3]f64, null), empty.point_at_distance(0.0));
}

test "slice_between_distances: full, partial, zero-length, and invalid ranges" {
    var trace = try Trace.init(testing.allocator, &line_points);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), trace.slice_between_distances(0.0, 400.0).?.len);
    const partial = trace.slice_between_distances(50.0, 200.0).?;
    try testing.expectEqualSlices([3]f64, line_points[1..3], partial);
    try testing.expectEqual(@as(usize, 1), trace.slice_between_distances(0.0, 0.0).?.len);
    try testing.expectEqual(@as(usize, 1), trace.slice_between_distances(500.0, 1000.0).?.len);
    try testing.expectEqual(@as(?[][3]f64, null), trace.slice_between_distances(111.0, 0.0));
    try testing.expectEqual(@as(?[][3]f64, null), trace.slice_between_distances(-100.0, 100.0));
}

test "closest_point: the nearest point, the first of equals, and none on an empty trace" {
    const points = [_][3]f64{
        .{ 1.0, 1.0, 100.0 },
        .{ 1.0, 1.0, 100.0 },
        .{ 2.0, 2.0, 200.0 },
        .{ 3.0, 3.0, 115.0 },
    };
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);

    const exact = trace.closest_point(.{ 1.0, 1.0, 0.0 }).?;
    try testing.expectEqual(@as(usize, 0), exact.index);
    try testing.expectEqual(@as(f64, 0), exact.distance_m);
    const far = trace.closest_point(.{ 10.0, 10.0, 0.0 }).?;
    try testing.expectEqual(@as(usize, 3), far.index);
    try testing.expectEqual(points[3], far.point);

    var empty = try Trace.init(testing.allocator, &.{});
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(?ClosestPoint, null), empty.closest_point(.{ 0.0, 0.0, 0.0 }));
    try testing.expectEqual(@as(?ClosestPoint, null), trace.closest_point_after(.{ 0, 0, 0 }, 4));
}

test "closest_point_after: on a loop, the first close pass wins over a closer later one" {
    // W is about 7 m from the outbound pass (index 2) and 2 m from the return (index 6), so
    // the return is the global nearest. From the start, the scan locks onto index 2 and
    // stops at the turnaround, more than 2 km farther, before it reaches the return.
    const points = [_][3]f64{
        .{ 43.0, 0.0, 800.0 },
        .{ 43.0, 0.001, 810.0 },
        .{ 43.0, 0.002, 820.0 },
        .{ 43.0, 0.010, 900.0 },
        .{ 43.0, 0.020, 950.0 },
        .{ 43.0, 0.030, 930.0 },
        .{ 43.0, 0.0019, 820.0 },
        .{ 43.0, 0.001, 810.0 },
        .{ 43.0, 0.0, 800.0 },
    };
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    const waypoint = [3]f64{ 43.0, 0.00192, 0.0 };
    try testing.expectEqual(@as(usize, 2), trace.closest_point_after(waypoint, 0).?.index);
    try testing.expectEqual(@as(usize, 6), trace.closest_point_after(waypoint, 5).?.index);
}
