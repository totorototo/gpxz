//! Climbs: each peak paired with the valley before it, kept only when it qualifies the way
//! Garmin's ClimbPro does.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const ClimbStats = struct {
    index_start: usize,
    index_end: usize,
    distance_m_start: f64,
    distance_m: f64,
    elevation_gain_m: f64,
    elevation_m_summit: f64,
    gradient_percent_average: f64,
};

/// A climb qualifies only when all three hold: it is long enough, steep enough, and its
/// length × gradient score is high enough.
const climb_distance_m_min = 500.0;
const gradient_percent_min = 3.0;
/// In meters × percent. The comparison is strict: exactly this score doesn't qualify.
const score_min = 3_500.0;

/// Returns the climbs that end at each peak, in order. Each starts at the nearest detected
/// valley before its peak, or at the trail start when none precedes it: races usually start
/// low, and Garmin ClimbPro makes the same choice. `peaks` and `valleys` are sorted
/// ascending. The caller owns the result.
pub fn climbs_detect(
    allocator: std.mem.Allocator,
    peaks: []const usize,
    valleys: []const usize,
    points: []const [3]f64,
    distances_m: []const f64,
) ![]ClimbStats {
    assert(points.len == distances_m.len);
    assert(std.sort.isSorted(usize, peaks, {}, std.sort.asc(usize)));
    assert(std.sort.isSorted(usize, valleys, {}, std.sort.asc(usize)));
    if (peaks.len == 0) return allocator.alloc(ClimbStats, 0);
    assert(peaks[peaks.len - 1] < points.len);

    var climbs: std.ArrayList(ClimbStats) = .empty;
    defer climbs.deinit(allocator);
    // Walks the sorted valleys along with the peaks: after the inner loop, it is the last
    // valley strictly before the current peak, if any.
    var valley_cursor: usize = 0;
    // A climb may only start after the previous climb's peak, so no two climbs overlap.
    var start_min: usize = 0;
    for (peaks) |peak| {
        while (valley_cursor + 1 < valleys.len and valleys[valley_cursor + 1] < peak) {
            valley_cursor += 1;
        }
        const valley_detected: usize =
            if (valleys.len > 0 and valleys[valley_cursor] < peak) valleys[valley_cursor] else 0;
        // The nearest valley may belong to the previous climb. Rather than drop this peak,
        // start from the lowest point after the previous climb.
        const valley = if (valley_detected < start_min)
            lowest_index(points, start_min, peak) orelse start_min
        else
            valley_detected;
        if (valley >= peak) continue;

        const climb = climb_stats(points, distances_m, valley, peak);
        if (!qualifies(climb.distance_m, climb.gradient_percent_average)) continue;
        try climbs.append(allocator, climb);
        start_min = peak;
    }
    assert(climbs.items.len <= peaks.len);
    return climbs.toOwnedSlice(allocator);
}

fn climb_stats(
    points: []const [3]f64,
    distances_m: []const f64,
    valley: usize,
    peak: usize,
) ClimbStats {
    assert(valley < peak);
    assert(peak < points.len);
    const distance_m_start = distances_m[valley];
    const distance_m_end = distances_m[peak];
    const distance_m = if (distance_m_end > distance_m_start)
        distance_m_end - distance_m_start
    else
        0.0;
    const elevation_m_valley = points[valley][2];
    const elevation_m_summit = points[peak][2];
    const elevation_gain_m = if (elevation_m_summit > elevation_m_valley)
        elevation_m_summit - elevation_m_valley
    else
        0.0;
    const gradient = if (distance_m > 0.0) (elevation_gain_m / distance_m) * 100.0 else 0.0;
    assert(distance_m >= 0 and elevation_gain_m >= 0 and gradient >= 0);
    return .{
        .index_start = valley,
        .index_end = peak,
        .distance_m_start = distance_m_start,
        .distance_m = distance_m,
        .elevation_gain_m = elevation_gain_m,
        .elevation_m_summit = elevation_m_summit,
        .gradient_percent_average = gradient,
    };
}

fn qualifies(distance_m: f64, gradient_percent: f64) bool {
    assert(distance_m >= 0);
    assert(gradient_percent >= 0);
    return distance_m >= climb_distance_m_min and
        gradient_percent >= gradient_percent_min and
        distance_m * gradient_percent > score_min;
}

/// Returns the index of the lowest point in [start, end), or null if the range is empty.
fn lowest_index(points: []const [3]f64, start: usize, end: usize) ?usize {
    assert(end <= points.len);
    if (start >= end) return null;
    var lowest = start;
    for (start + 1..end) |index| {
        if (points[index][2] < points[lowest][2]) lowest = index;
    }
    assert(lowest >= start and lowest < end);
    return lowest;
}

test "climbs_detect: no peaks, no climbs" {
    const empty = try climbs_detect(testing.allocator, &.{}, &.{}, &.{}, &.{});
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const points = [_][3]f64{ .{ 0.0, 0.0, 100.0 }, .{ 0.0, 0.1, 200.0 } };
    const distances_m = [_]f64{ 0.0, 1000.0 };
    const climbs = try climbs_detect(testing.allocator, &.{}, &.{}, &points, &distances_m);
    defer testing.allocator.free(climbs);
    try testing.expectEqual(@as(usize, 0), climbs.len);
}

test "climbs_detect: one peak from a valley" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 }, // Valley.
        .{ 0.0, 0.1, 200.0 },
        .{ 0.0, 0.2, 350.0 },
        .{ 0.0, 0.3, 450.0 },
        .{ 0.0, 0.4, 500.0 }, // Peak.
    };
    const distances_m = [_]f64{ 0.0, 1000.0, 2000.0, 3000.0, 4000.0 };
    const climbs = try climbs_detect(testing.allocator, &.{4}, &.{0}, &points, &distances_m);
    defer testing.allocator.free(climbs);

    try testing.expectEqual(@as(usize, 1), climbs.len);
    try testing.expectEqual(ClimbStats{
        .index_start = 0,
        .index_end = 4,
        .distance_m_start = 0.0,
        .distance_m = 4000.0,
        .elevation_gain_m = 400.0,
        .elevation_m_summit = 500.0,
        .gradient_percent_average = 10.0,
    }, climbs[0]);
}

test "climbs_detect: with no valley before a peak, the climb starts at the trail start" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 0.0, 0.1, 300.0 },
        .{ 0.0, 0.2, 500.0 }, // Peak.
    };
    const distances_m = [_]f64{ 0.0, 1000.0, 2000.0 };
    const climbs = try climbs_detect(testing.allocator, &.{2}, &.{}, &points, &distances_m);
    defer testing.allocator.free(climbs);
    try testing.expectEqual(@as(usize, 1), climbs.len);
    try testing.expectEqual(@as(usize, 0), climbs[0].index_start);
}

test "climbs_detect: the second climb starts at the valley between the peaks" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 0.0, 0.1, 200.0 },
        .{ 0.0, 0.2, 300.0 }, // First peak.
        .{ 0.0, 0.3, 150.0 },
        .{ 0.0, 0.4, 80.0 }, // Valley between the peaks.
        .{ 0.0, 0.5, 200.0 },
        .{ 0.0, 0.6, 400.0 }, // Second peak.
    };
    const distances_m = [_]f64{ 0.0, 1000.0, 2000.0, 3000.0, 4000.0, 5000.0, 6000.0 };
    const peaks = [_]usize{ 2, 6 };
    const valleys = [_]usize{ 0, 4 };
    const climbs = try climbs_detect(testing.allocator, &peaks, &valleys, &points, &distances_m);
    defer testing.allocator.free(climbs);

    try testing.expectEqual(@as(usize, 2), climbs.len);
    try testing.expectEqual(@as(usize, 4), climbs[1].index_start);
    try testing.expectEqual(@as(usize, 6), climbs[1].index_end);
    try testing.expectEqual(@as(f64, 320.0), climbs[1].elevation_gain_m);
    try testing.expectEqual(@as(f64, 400.0), climbs[1].elevation_m_summit);
}

test "climbs_detect: a claimed valley falls back to the lowest unclaimed point" {
    // No valley was detected between the peaks, and the one at 0 belongs to climb A.
    // Climb A: 0 (100 m) to 2 (600 m) over 2000 m, 25%.
    // Climb B: 3 (580 m) to 4 (700 m) over 1500 m, 8%, score 12000.
    const points = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 0.0, 0.1, 200.0 },
        .{ 0.0, 0.2, 600.0 }, // Peak A.
        .{ 0.0, 0.3, 580.0 }, // An undetected dip.
        .{ 0.0, 0.4, 700.0 }, // Peak B.
    };
    const distances_m = [_]f64{ 0.0, 500.0, 2000.0, 2500.0, 4000.0 };
    const climbs = try climbs_detect(testing.allocator, &.{ 2, 4 }, &.{0}, &points, &distances_m);
    defer testing.allocator.free(climbs);

    try testing.expectEqual(@as(usize, 2), climbs.len);
    try testing.expectEqual(@as(usize, 0), climbs[0].index_start);
    try testing.expectEqual(@as(usize, 2), climbs[0].index_end);
    try testing.expectEqual(@as(usize, 3), climbs[1].index_start);
    try testing.expectEqual(@as(usize, 4), climbs[1].index_end);
}

test "climbs_detect: the Garmin qualification filter" {
    // Six valley-to-peak climbs; only the last one qualifies:
    //   A: 400 m, 5%     too short
    //   B: 600 m, 1.67%  too shallow
    //   C: 500 m, 3%     score 1500
    //   D: 600 m, 5%     score 3000
    //   E: 700 m, 5%     score 3500, exactly the minimum, which doesn't qualify
    //   F: 800 m, 6%     score 4800
    const points = [_][3]f64{
        .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.1, 20.0 },
        .{ 0.0, 0.2, 0.0 }, .{ 0.0, 0.3, 10.0 },
        .{ 0.0, 0.4, 0.0 }, .{ 0.0, 0.5, 15.0 },
        .{ 0.0, 0.6, 0.0 }, .{ 0.0, 0.7, 30.0 },
        .{ 0.0, 0.8, 0.0 }, .{ 0.0, 0.9, 35.0 },
        .{ 0.0, 1.0, 0.0 }, .{ 0.0, 1.1, 48.0 },
    };
    const distances_m = [_]f64{
        0.0,    400.0,
        800.0,  1400.0,
        1800.0, 2300.0,
        2700.0, 3300.0,
        3700.0, 4400.0,
        4800.0, 5600.0,
    };
    const peaks = [_]usize{ 1, 3, 5, 7, 9, 11 };
    const valleys = [_]usize{ 0, 2, 4, 6, 8, 10 };
    const climbs = try climbs_detect(testing.allocator, &peaks, &valleys, &points, &distances_m);
    defer testing.allocator.free(climbs);

    try testing.expectEqual(@as(usize, 1), climbs.len);
    try testing.expectEqual(@as(usize, 10), climbs[0].index_start);
    try testing.expectEqual(@as(usize, 11), climbs[0].index_end);
    try testing.expectEqual(@as(f64, 48.0), climbs[0].elevation_m_summit);
    try testing.expectEqual(@as(f64, 800.0), climbs[0].distance_m);
    try testing.expectEqual(@as(f64, 6.0), climbs[0].gradient_percent_average);
}

test "qualifies: each bound on its own" {
    try testing.expect(qualifies(800.0, 6.0));
    try testing.expect(qualifies(climb_distance_m_min, 8.0));
    try testing.expect(!qualifies(climb_distance_m_min - 1.0, 20.0));
    try testing.expect(qualifies(2000.0, gradient_percent_min));
    try testing.expect(!qualifies(10_000.0, gradient_percent_min - 0.01));
    try testing.expect(!qualifies(700.0, 5.0));
    try testing.expect(!qualifies(0.0, 0.0));
}

test "lowest_index: the range is half-open, and empty returns null" {
    const points = [_][3]f64{ .{ 0, 0, 5 }, .{ 0, 0, 1 }, .{ 0, 0, 3 }, .{ 0, 0, 0 } };
    try testing.expectEqual(@as(?usize, 1), lowest_index(&points, 0, 3));
    try testing.expectEqual(@as(?usize, 3), lowest_index(&points, 0, 4));
    try testing.expectEqual(@as(?usize, 2), lowest_index(&points, 2, 3));
    try testing.expectEqual(@as(?usize, null), lowest_index(&points, 2, 2));
    try testing.expectEqual(@as(?usize, null), lowest_index(&points, 3, 2));
}
