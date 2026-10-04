//! Climbs: each peak paired with the valley before it, kept only when it qualifies the way
//! Garmin's ClimbPro does. Descents: the climbs of the profile mirrored upside down, so they
//! qualify by the same rules.

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

/// From a top down to a bottom: a climb of the mirrored profile, the drop measured as a loss.
pub const DescentStats = struct {
    index_start: usize,
    index_end: usize,
    distance_m_start: f64,
    distance_m: f64,
    elevation_loss_m: f64,
    elevation_m_top: f64,
    /// The average drop over distance, as a positive percent.
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

/// Returns the descents that end at each valley, in order: the climbs of the profile turned
/// upside down, where the valleys are the peaks. A descent qualifies by the climbs' rules
/// (length, gradient, score), so a long gentle run-out isn't one and a steep drop is.
/// why: mirroring, not a second detector: one set of rules can't drift from the other. The
/// caller owns the result.
pub fn descents_detect(
    allocator: std.mem.Allocator,
    peaks: []const usize,
    valleys: []const usize,
    points: []const [3]f64,
    distances_m: []const f64,
) ![]DescentStats {
    assert(points.len == distances_m.len);
    const mirrored = try allocator.alloc([3]f64, points.len);
    defer allocator.free(mirrored);
    for (points, mirrored) |point, *flipped| flipped.* = .{ point[0], point[1], -point[2] };
    const bottoms = try bottoms_with_finish(allocator, peaks, valleys, points);
    defer allocator.free(bottoms);
    const climbs = try climbs_detect(allocator, bottoms, peaks, mirrored, distances_m);
    defer allocator.free(climbs);

    const descents = try allocator.alloc(DescentStats, climbs.len);
    for (climbs, descents) |*climb, *descent| {
        descent.* = .{
            .index_start = climb.index_start,
            .index_end = climb.index_end,
            .distance_m_start = climb.distance_m_start,
            .distance_m = climb.distance_m,
            .elevation_loss_m = climb.elevation_gain_m,
            .elevation_m_top = points[climb.index_start][2],
            .gradient_percent_average = climb.gradient_percent_average,
        };
        // Paired with the mirroring: each descent ends lower than it starts, by its loss.
        const drop_m = points[descent.index_start][2] - points[descent.index_end][2];
        assert(drop_m >= 0 and @abs(drop_m - descent.elevation_loss_m) < 1e-9);
    }
    assert(descents.len <= bottoms.len);
    return descents;
}

/// The valleys, plus the trail's last point when it lies below the last peak and no valley
/// follows that peak. why: the twin of the climbs' rule that a climb with no valley before it
/// starts at the trail start. The peak detector never returns an end point, and a race that
/// runs down to its finish ends on the longest descent of all; a summit finish is rare, so
/// climbs don't need the rule. The caller owns the result.
fn bottoms_with_finish(
    allocator: std.mem.Allocator,
    peaks: []const usize,
    valleys: []const usize,
    points: []const [3]f64,
) ![]usize {
    assert(std.sort.isSorted(usize, valleys, {}, std.sort.asc(usize)));
    if (points.len == 0 or peaks.len == 0) return allocator.dupe(usize, valleys);
    const last = points.len - 1;
    const peak_last = peaks[peaks.len - 1];
    const valley_after = valleys.len > 0 and valleys[valleys.len - 1] > peak_last;
    const finish_low = peak_last < last and points[last][2] < points[peak_last][2];
    if (valley_after or !finish_low) return allocator.dupe(usize, valleys);
    const bottoms = try allocator.alloc(usize, valleys.len + 1);
    @memcpy(bottoms[0..valleys.len], valleys);
    bottoms[valleys.len] = last;
    assert(std.sort.isSorted(usize, bottoms, {}, std.sort.asc(usize)));
    return bottoms;
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

test "descents_detect: one valley from a peak, the drop as a loss" {
    const points = [_][3]f64{
        .{ 0.0, 0.0, 500.0 }, // Peak.
        .{ 0.0, 0.1, 450.0 },
        .{ 0.0, 0.2, 350.0 },
        .{ 0.0, 0.3, 200.0 },
        .{ 0.0, 0.4, 100.0 }, // Valley.
    };
    const distances_m = [_]f64{ 0.0, 1000.0, 2000.0, 3000.0, 4000.0 };
    const descents = try descents_detect(testing.allocator, &.{0}, &.{4}, &points, &distances_m);
    defer testing.allocator.free(descents);

    try testing.expectEqual(@as(usize, 1), descents.len);
    try testing.expectEqual(DescentStats{
        .index_start = 0,
        .index_end = 4,
        .distance_m_start = 0.0,
        .distance_m = 4000.0,
        .elevation_loss_m = 400.0,
        .elevation_m_top = 500.0,
        .gradient_percent_average = 10.0,
    }, descents[0]);
}

test "descents_detect: no valleys, no descents; a short drop doesn't qualify" {
    // Up to the finish: no valley, and the finish no bottom either.
    const points = [_][3]f64{ .{ 0.0, 0.0, 200.0 }, .{ 0.0, 0.1, 300.0 } };
    const distances_m = [_]f64{ 0.0, 1000.0 };
    const none = try descents_detect(testing.allocator, &.{0}, &.{}, &points, &distances_m);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // 400 m at 25 %: under the 500 m minimum, as a climb would be.
    const short = [_][3]f64{ .{ 0.0, 0.0, 200.0 }, .{ 0.0, 0.1, 100.0 } };
    const short_m = [_]f64{ 0.0, 400.0 };
    const dropped = try descents_detect(testing.allocator, &.{0}, &.{1}, &short, &short_m);
    defer testing.allocator.free(dropped);
    try testing.expectEqual(@as(usize, 0), dropped.len);
}

test "descents_detect: a climb's mirror image is a descent of the same shape" {
    const up = [_][3]f64{
        .{ 0.0, 0.0, 100.0 },
        .{ 0.0, 0.1, 300.0 },
        .{ 0.0, 0.2, 600.0 }, // Peak.
        .{ 0.0, 0.3, 350.0 },
        .{ 0.0, 0.4, 120.0 }, // Valley.
    };
    const distances_m = [_]f64{ 0.0, 1000.0, 2000.0, 3000.0, 4000.0 };
    const climbs = try climbs_detect(testing.allocator, &.{2}, &.{0}, &up, &distances_m);
    defer testing.allocator.free(climbs);
    const descents = try descents_detect(testing.allocator, &.{2}, &.{ 0, 4 }, &up, &distances_m);
    defer testing.allocator.free(descents);
    try testing.expectEqual(@as(usize, 1), climbs.len);
    try testing.expectEqual(@as(usize, 1), descents.len);
    try testing.expectEqual(@as(usize, 2), descents[0].index_start);
    try testing.expectEqual(@as(usize, 4), descents[0].index_end);
    try testing.expectEqual(@as(f64, 480.0), descents[0].elevation_loss_m);
    try testing.expectEqual(@as(f64, 600.0), descents[0].elevation_m_top);
}

test "descents_detect: a run down to the finish ends at the finish" {
    // The last valley is at 1; the trail then climbs to a peak at 3 and runs down to the end,
    // where the peak detector finds no valley.
    const points = [_][3]f64{
        .{ 0.0, 0.0, 300.0 },
        .{ 0.0, 0.1, 100.0 }, // Valley.
        .{ 0.0, 0.2, 400.0 },
        .{ 0.0, 0.3, 900.0 }, // Peak.
        .{ 0.0, 0.4, 600.0 },
        .{ 0.0, 0.5, 300.0 }, // The finish.
    };
    const distances_m = [_]f64{ 0.0, 1000.0, 2000.0, 3000.0, 4000.0, 5000.0 };
    const descents = try descents_detect(testing.allocator, &.{3}, &.{1}, &points, &distances_m);
    defer testing.allocator.free(descents);
    const last = descents[descents.len - 1];
    try testing.expectEqual(@as(usize, 3), last.index_start);
    try testing.expectEqual(@as(usize, 5), last.index_end);
    try testing.expectEqual(@as(f64, 600.0), last.elevation_loss_m);
}

test "bottoms_with_finish: only a finish below the last peak, with no valley after it" {
    const points = [_][3]f64{ .{ 0, 0, 100 }, .{ 0, 0, 500 }, .{ 0, 0, 200 }, .{ 0, 0, 300 } };
    const Case = struct { peaks: []const usize, valleys: []const usize, expected: []const usize };
    const cases = [_]Case{
        // Below the peak at 1, no valley after it: the finish joins.
        .{ .peaks = &.{1}, .valleys = &.{0}, .expected = &.{ 0, 3 } },
        // A valley after the last peak already ends the descent.
        .{ .peaks = &.{1}, .valleys = &.{ 0, 2 }, .expected = &.{ 0, 2 } },
        // No peak: nothing to come down from.
        .{ .peaks = &.{}, .valleys = &.{0}, .expected = &.{0} },
        // The finish is the peak itself.
        .{ .peaks = &.{3}, .valleys = &.{0}, .expected = &.{0} },
    };
    for (cases) |case| {
        const bottoms =
            try bottoms_with_finish(testing.allocator, case.peaks, case.valleys, &points);
        defer testing.allocator.free(bottoms);
        try testing.expectEqualSlices(usize, case.expected, bottoms);
    }
}
