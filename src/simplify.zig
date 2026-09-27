//! Douglas-Peucker simplification of a GPS path. Timings live in src/bench.zig
//! (`zig build bench`), not in the tests, so a slow machine can't fail `zig build test`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const distance = @import("gps_point.zig").distance;

/// Below this length a segment is treated as a point: the height of a triangle over a base
/// this short would divide by almost zero.
const segment_length_min_m = 0.001;

/// Returns the distance in meters from `point` to the line through `line_start` and
/// `line_end`. It uses the 2D Haversine distance and ignores elevation, so simplification
/// keeps the horizontal shape of the path instead of following elevation noise.
pub fn perpendicular_distance(point: [3]f64, line_start: [3]f64, line_end: [3]f64) f64 {
    const line_m = distance(line_start, line_end);
    assert(line_m >= 0);
    if (line_m < segment_length_min_m) return distance(point, line_start);

    const start_to_point_m = distance(line_start, point);
    const end_to_point_m = distance(line_end, point);
    // The height is 2 × area / base. Kahan's stable area avoids the cancellation that
    // Heron's formula suffers on needle triangles, which dominate Douglas-Peucker because
    // most points lie almost on the line.
    const area_m2 = triangle_area(line_m, start_to_point_m, end_to_point_m);
    const height_m = (2.0 * area_m2) / line_m;
    assert(height_m >= 0);
    // The height can't exceed the shorter of the two other sides, give or take rounding.
    assert(height_m <= @min(start_to_point_m, end_to_point_m) + 1e-6);
    return height_m;
}

/// Returns a triangle's area from its three side lengths, stable on needle triangles
/// (Kahan, 2014), and 0 for a degenerate (collinear) one.
fn triangle_area(side_a: f64, side_b: f64, side_c: f64) f64 {
    assert(side_a >= 0 and side_b >= 0 and side_c >= 0);
    var a = side_a;
    var b = side_b;
    var c = side_c;
    // Sort so that a >= b >= c: each subtraction below then stays well-conditioned.
    if (a < b) std.mem.swap(f64, &a, &b);
    if (b < c) std.mem.swap(f64, &b, &c);
    if (a < b) std.mem.swap(f64, &a, &b);
    assert(a >= b and b >= c);

    const t = (a + (b + c)) * (c - (a - b)) * (c + (a - b)) * (a + (b - c));
    if (t <= 0.0) return 0.0;
    const area = 0.25 * @sqrt(t);
    assert(area > 0);
    return area;
}

/// Returns the indices, ascending, of the points that survive Douglas-Peucker with tolerance
/// `epsilon_m`. The endpoints are always kept. The caller owns the returned slice.
///
/// It uses a keep mask and an explicit work stack instead of recursion, so a deeply
/// subdividing path can't overflow the call stack.
pub fn douglas_peucker_indices(
    allocator: std.mem.Allocator,
    points: []const [3]f64,
    epsilon_m: f64,
) ![]usize {
    assert(epsilon_m >= 0 and std.math.isFinite(epsilon_m));
    if (points.len <= 2) {
        const indices = try allocator.alloc(usize, points.len);
        for (indices, 0..) |*index, position| index.* = position;
        return indices;
    }

    const keep = try allocator.alloc(bool, points.len);
    defer allocator.free(keep);
    @memset(keep, false);
    keep[0] = true;
    keep[points.len - 1] = true;

    const Segment = struct { low: usize, high: usize };
    var stack: std.ArrayList(Segment) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .low = 0, .high = points.len - 1 });

    // Bounded: a segment splits only by keeping a new interior point, so at most
    // points.len - 2 splits push 2 segments each, on top of the first one.
    const iterations_max = 2 * points.len;
    var iterations: usize = 0;
    while (stack.pop()) |segment| {
        iterations += 1;
        assert(iterations <= iterations_max);
        assert(segment.low < segment.high);
        assert(segment.high < points.len);

        const farthest = farthest_point(points, segment.low, segment.high);
        if (farthest.distance_m > epsilon_m) {
            assert(!keep[farthest.index]);
            keep[farthest.index] = true;
            try stack.append(allocator, .{ .low = segment.low, .high = farthest.index });
            try stack.append(allocator, .{ .low = farthest.index, .high = segment.high });
        }
    }

    const kept = std.mem.count(bool, keep, &.{true});
    const indices = try allocator.alloc(usize, kept);
    var position: usize = 0;
    for (keep, 0..) |is_kept, index| {
        if (!is_kept) continue;
        indices[position] = index;
        position += 1;
    }
    assert(position == kept);
    assert(indices[0] == 0);
    assert(indices[indices.len - 1] == points.len - 1);
    return indices;
}

const Farthest = struct { index: usize, distance_m: f64 };

/// Returns the point strictly between `low` and `high` farthest from the line through them.
/// An adjacent pair has no interior point, so it returns distance 0 and never splits.
fn farthest_point(points: []const [3]f64, low: usize, high: usize) Farthest {
    assert(low < high);
    assert(high < points.len);
    var farthest: Farthest = .{ .index = low, .distance_m = 0.0 };
    for (low + 1..high) |index| {
        const distance_m = perpendicular_distance(points[index], points[low], points[high]);
        if (distance_m > farthest.distance_m) {
            farthest = .{ .index = index, .distance_m = distance_m };
        }
    }
    assert(farthest.distance_m == 0 or (farthest.index > low and farthest.index < high));
    return farthest;
}

/// Returns the points that survive Douglas-Peucker: a thin wrapper over
/// `douglas_peucker_indices`. The caller owns the returned slice.
pub fn douglas_peucker_simplify(
    allocator: std.mem.Allocator,
    points: []const [3]f64,
    epsilon_m: f64,
) ![][3]f64 {
    const indices = try douglas_peucker_indices(allocator, points, epsilon_m);
    defer allocator.free(indices);

    const simplified = try allocator.alloc([3]f64, indices.len);
    for (simplified, indices) |*point, index| point.* = points[index];
    assert(simplified.len <= points.len);
    return simplified;
}

test "douglas_peucker_indices: ascending indices that map back to the surviving points" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 1.0, 0.0, 100.0 },
        .{ 2.0, 5.0, 110.0 }, // The peak must survive.
        .{ 3.0, 0.0, 100.0 },
        .{ 4.0, 0.0, 100.0 },
    };

    const indices = try douglas_peucker_indices(testing.allocator, &points, 1.0);
    defer testing.allocator.free(indices);
    for (1..indices.len) |position| try testing.expect(indices[position] > indices[position - 1]);
    try testing.expectEqual(@as(usize, 0), indices[0]);
    try testing.expectEqual(points.len - 1, indices[indices.len - 1]);
    try testing.expect(std.mem.indexOfScalar(usize, indices, 2) != null);

    // The indices select exactly the points the slice API returns.
    const simplified = try douglas_peucker_simplify(testing.allocator, &points, 1.0);
    defer testing.allocator.free(simplified);
    try testing.expectEqual(indices.len, simplified.len);
    for (indices, simplified) |index, point| try testing.expectEqual(points[index], point);
}

test "douglas_peucker_indices: 0, 1 and 2 points come back unchanged" {
    const points = [_][3]f64{ .{ 0.0, 0.0, 100.0 }, .{ 1.0, 1.0, 105.0 } };
    for (0..points.len + 1) |count| {
        const indices = try douglas_peucker_indices(testing.allocator, points[0..count], 1.0);
        defer testing.allocator.free(indices);
        try testing.expectEqual(count, indices.len);
        for (indices, 0..) |index, position| try testing.expectEqual(position, index);
    }
}

test "douglas_peucker_indices: identical points reduce to the endpoints" {
    const points = [_][3]f64{.{ 45.0, -122.0, 100.0 }} ** 5;
    const indices = try douglas_peucker_indices(testing.allocator, &points, 0.0);
    defer testing.allocator.free(indices);
    try testing.expectEqualSlices(usize, &.{ 0, 4 }, indices);
}

test "douglas_peucker_indices: epsilon 0 keeps every point off the line" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 0.001, 0.001, 100.0 },
        .{ 0.0, 0.002, 100.0 },
        .{ 0.001, 0.003, 100.0 },
    };
    const indices = try douglas_peucker_indices(testing.allocator, &points, 0.0);
    defer testing.allocator.free(indices);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, indices);
}

test "douglas_peucker_indices: a long switchback path stays within the iteration bound" {
    // The input shape `zig build bench` times, at a size tests can afford. The loop's
    // iteration assertion is what this checks.
    const count = 2_000;
    const points = try testing.allocator.alloc([3]f64, count);
    defer testing.allocator.free(points);
    for (points, 0..) |*point, index| {
        const t = @as(f64, @floatFromInt(index)) / count;
        point.* = .{ 45.0 + t * 0.5, -122.0 + t * 0.3 + @sin(t * std.math.pi * 30.0) * 0.002, 0 };
    }

    const indices = try douglas_peucker_indices(testing.allocator, points, 10.0);
    defer testing.allocator.free(indices);
    try testing.expect(indices.len > 2);
    try testing.expect(indices.len < count / 10);
}

test "perpendicular_distance: a point on the line is at 0 m" {
    const line_start = [3]f64{ 0.0, 0.0, 0.0 };
    const line_end = [3]f64{ 0.0, 0.001, 0.0 }; // About 111 m apart.
    const midpoint = [3]f64{ 0.0, 0.0005, 0.0 };
    // Heron's formula needed a 100 m tolerance here, because of cancellation.
    const distance_m = perpendicular_distance(midpoint, line_start, line_end);
    try testing.expectApproxEqAbs(0.0, distance_m, 0.01);
}

test "perpendicular_distance: a point 0.001° off a line on the equator is about 111 m away" {
    const line_start = [3]f64{ 0.0, 0.0, 0.0 };
    const line_end = [3]f64{ 0.0, 0.001, 0.0 };
    const point = [3]f64{ 0.001, 0.0005, 0.0 };
    try testing.expectApproxEqAbs(111.2, perpendicular_distance(point, line_start, line_end), 0.5);
}

test "perpendicular_distance: elevation is ignored" {
    const line_start = [3]f64{ 0.0, 0.0, 100.0 };
    const line_end = [3]f64{ 0.0, 0.001, 100.0 };
    const flat = perpendicular_distance(.{ 0.001, 0.0005, 100.0 }, line_start, line_end);
    const raised = perpendicular_distance(.{ 0.001, 0.0005, 150.0 }, line_start, line_end);
    try testing.expectEqual(flat, raised);
}

test "perpendicular_distance: a zero-length line measures to its start" {
    const line_start = [3]f64{ 45.0, -122.0, 100.0 };
    const point = [3]f64{ 45.001, -122.0, 100.0 };
    const expected_m = distance(point, line_start);
    try testing.expectEqual(expected_m, perpendicular_distance(point, line_start, line_start));
    const self_m = perpendicular_distance(line_start, line_start, line_start);
    try testing.expectEqual(@as(f64, 0), self_m);
}

test "triangle_area: stable on a needle triangle" {
    // The apex sits 0.02 above a base of 1000. For an isosceles triangle the height is
    // sqrt((leg - half) × (leg + half)), where the subtraction is exact, so it is a reference
    // free of the cancellation Heron's formula suffers.
    const leg = 500.0000005;
    const height_expected = @sqrt((leg - 500.0) * (leg + 500.0));
    const area = triangle_area(1000.0, leg, leg);
    try testing.expectApproxEqRel(500.0 * height_expected, area, 1e-6);
}

test "triangle_area: a degenerate triangle has area 0" {
    try testing.expectEqual(@as(f64, 0), triangle_area(10.0, 6.0, 4.0));
    try testing.expectEqual(@as(f64, 0), triangle_area(0.0, 0.0, 0.0));
}

test "triangle_area: the 3-4-5 right triangle has area 6 in any side order" {
    try testing.expectApproxEqAbs(6.0, triangle_area(3.0, 4.0, 5.0), 1e-9);
    try testing.expectApproxEqAbs(6.0, triangle_area(5.0, 4.0, 3.0), 1e-9);
    try testing.expectApproxEqAbs(6.0, triangle_area(4.0, 5.0, 3.0), 1e-9);
}

test "douglas_peucker_simplify: a straight line reduces to its endpoints" {
    // Points about 11 m apart due north, with a 100 m tolerance.
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 0.0, 0.0001, 100.0 },
        .{ 0.0, 0.0002, 100.0 },
        .{ 0.0, 0.0003, 100.0 },
        .{ 0.0, 0.0004, 100.0 },
    };
    const simplified = try douglas_peucker_simplify(testing.allocator, &points, 100.0);
    defer testing.allocator.free(simplified);
    try testing.expectEqualSlices([3]f64, &.{ points[0], points[4] }, simplified);
}

test "douglas_peucker_simplify: a larger epsilon keeps no more points" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 1.0, 0.1, 100.0 },
        .{ 2.0, 0.2, 100.0 },
        .{ 3.0, 0.1, 100.0 },
        .{ 4.0, 0.0, 100.0 },
    };
    const strict = try douglas_peucker_simplify(testing.allocator, &points, 0.01);
    defer testing.allocator.free(strict);
    const loose = try douglas_peucker_simplify(testing.allocator, &points, 1.0);
    defer testing.allocator.free(loose);
    try testing.expect(loose.len <= strict.len);
    try testing.expect(loose.len >= 2);
}
