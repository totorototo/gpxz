//! Denoised elevation gain and loss (D+/D-) and smoothed slopes. GPS elevation is noisy in
//! two ways: spikes, which a distance-windowed median rejects, and low-amplitude jitter, which
//! a hysteresis deadband rejects. Without both, D+/D- inflates with every wobble.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const distance = @import("gps_point.zig").distance;

/// Elevation changes smaller than this are jitter, not terrain.
pub const noise_threshold_m = 3.0;
/// The median window reaches this far on each side of a point.
pub const median_radius_m = 15.0;
/// A cap on the median window, so dense points (a stopped watch logging in place) can't make
/// each median sort thousands of samples.
const window_samples_max = 256;

/// The slope window reaches this far on each side of a point. GPX elevation is often only
/// 1 m accurate, so a short window turns that rounding into spurious grade swings (1 m over
/// 10 m reads as 10%). Matching the median radius keeps the grade consistent with the
/// denoised elevation.
pub const slope_window_half_m = median_radius_m;

pub const GainLoss = struct {
    gains_m_cumulative: []f64,
    losses_m_cumulative: []f64,
    gain_m_total: f64,
    loss_m_total: f64,

    pub fn deinit(self: *GainLoss, allocator: std.mem.Allocator) void {
        allocator.free(self.gains_m_cumulative);
        allocator.free(self.losses_m_cumulative);
        self.* = undefined;
    }
};

/// Returns the denoised gain and loss of `points`: a median over `radius_m` on each side,
/// then a deadband of `threshold_m`. The caller owns the result.
pub fn gain_loss_compute(
    allocator: std.mem.Allocator,
    points: []const [3]f64,
    radius_m: f64,
    threshold_m: f64,
) !GainLoss {
    assert(radius_m >= 0);
    assert(threshold_m >= 0);
    const distances_m = try distances_cumulative(allocator, points);
    defer allocator.free(distances_m);
    const smoothed_m = try median_smooth(allocator, points, distances_m, radius_m);
    defer allocator.free(smoothed_m);
    return gain_loss_accumulate(allocator, smoothed_m, threshold_m);
}

/// Returns the horizontal distance from the first point to each point, in meters. The caller
/// owns the result.
pub fn distances_cumulative(allocator: std.mem.Allocator, points: []const [3]f64) ![]f64 {
    const distances_m = try allocator.alloc(f64, points.len);
    if (points.len == 0) return distances_m;
    distances_m[0] = 0.0;
    var total_m: f64 = 0.0;
    for (1..points.len) |index| {
        total_m += distance(points[index - 1], points[index]);
        distances_m[index] = total_m;
    }
    assert(distances_m[points.len - 1] == total_m);
    return distances_m;
}

/// Returns each point's elevation replaced by the median of the elevations within `radius_m`
/// along the path, capped at `window_samples_max` samples. The caller owns the result.
pub fn median_smooth(
    allocator: std.mem.Allocator,
    points: []const [3]f64,
    distances_m: []const f64,
    radius_m: f64,
) ![]f64 {
    assert(points.len == distances_m.len);
    assert(radius_m >= 0);
    const smoothed_m = try allocator.alloc(f64, points.len);
    errdefer allocator.free(smoothed_m);
    if (points.len == 0) return smoothed_m;
    const scratch = try allocator.alloc(f64, @min(points.len, window_samples_max));
    defer allocator.free(scratch);

    // The window [low, high] slides forward with the point, so each bound only increases.
    var low: usize = 0;
    var high: usize = 0;
    for (0..points.len) |index| {
        while (low < index and distances_m[index] - distances_m[low] > radius_m) low += 1;
        while (high + 1 < points.len and distances_m[high + 1] - distances_m[index] <= radius_m) {
            high += 1;
        }
        assert(low <= index and index <= high);

        var window_low = low;
        var window_high = high;
        if (window_high - window_low + 1 > window_samples_max) {
            const half = window_samples_max / 2;
            window_low = if (index > half) index - half else 0;
            window_high = @min(window_low + window_samples_max - 1, points.len - 1);
        }
        const count = window_high - window_low + 1;
        assert(count <= scratch.len);
        for (scratch[0..count], points[window_low..][0..count]) |*sample, point| {
            sample.* = point[2];
        }
        smoothed_m[index] = median(scratch[0..count]);
    }
    return smoothed_m;
}

/// Sorts `scratch` and returns its median.
fn median(scratch: []f64) f64 {
    assert(scratch.len > 0);
    std.mem.sort(f64, scratch, {}, std.sort.asc(f64));
    const middle = scratch.len / 2;
    if (scratch.len % 2 == 1) return scratch[middle];
    return (scratch[middle - 1] + scratch[middle]) / 2.0;
}

/// Accumulates gain and loss with a deadband: a change counts only once the elevation has
/// moved more than `threshold_m` from the last counted level. The caller owns the result.
pub fn gain_loss_accumulate(
    allocator: std.mem.Allocator,
    elevations_m: []const f64,
    threshold_m: f64,
) !GainLoss {
    assert(threshold_m >= 0);
    const gains_m_cumulative = try allocator.alloc(f64, elevations_m.len);
    errdefer allocator.free(gains_m_cumulative);
    const losses_m_cumulative = try allocator.alloc(f64, elevations_m.len);
    errdefer allocator.free(losses_m_cumulative);

    var gain_m: f64 = 0.0;
    var loss_m: f64 = 0.0;
    if (elevations_m.len > 0) {
        gains_m_cumulative[0] = 0.0;
        losses_m_cumulative[0] = 0.0;
        var level_m = elevations_m[0];
        for (elevations_m[1..], 1..) |elevation_m, index| {
            if (elevation_m > level_m + threshold_m) {
                gain_m += elevation_m - level_m;
                level_m = elevation_m;
            } else if (elevation_m < level_m - threshold_m) {
                loss_m += level_m - elevation_m;
                level_m = elevation_m;
            }
            gains_m_cumulative[index] = gain_m;
            losses_m_cumulative[index] = loss_m;
        }
    }
    assert(gain_m >= 0 and loss_m >= 0);
    return .{
        .gains_m_cumulative = gains_m_cumulative,
        .losses_m_cumulative = losses_m_cumulative,
        .gain_m_total = gain_m,
        .loss_m_total = loss_m,
    };
}

/// Returns the net grade in percent, 0 over no distance.
pub fn slope_percent_net(gain_m: f64, loss_m: f64, distance_m: f64) f64 {
    assert(gain_m >= 0 and loss_m >= 0 and distance_m >= 0);
    return if (distance_m > 0) ((gain_m - loss_m) / distance_m) * 100.0 else 0.0;
}

/// Returns the grade in percent at each point, over a centered window reaching at least
/// `slope_window_half_m` behind and ahead. The elevation is median-smoothed first, as for
/// D+/D-, so jitter isn't amplified into a fake steep grade. `distances_m` is the cumulative
/// horizontal distance aligned with `points`. The caller owns the result.
pub fn slopes_compute(
    allocator: std.mem.Allocator,
    points: []const [3]f64,
    distances_m: []const f64,
) ![]f64 {
    assert(points.len == distances_m.len);
    const slopes = try allocator.alloc(f64, points.len);
    errdefer allocator.free(slopes);
    if (points.len == 0) return slopes;

    const smoothed_m = try median_smooth(allocator, points, distances_m, median_radius_m);
    defer allocator.free(smoothed_m);
    for (slopes, 0..) |*slope, index| {
        const behind = index_behind(distances_m, index);
        const ahead = index_ahead(distances_m, index);
        assert(behind <= index and index <= ahead);
        const run_m = distances_m[ahead] - distances_m[behind];
        const rise_m = smoothed_m[ahead] - smoothed_m[behind];
        slope.* = if (run_m > 0.0) (rise_m / run_m) * 100.0 else 0.0;
    }
    return slopes;
}

/// Returns the last index before `index` at least `slope_window_half_m` behind it, or 0.
fn index_behind(distances_m: []const f64, index: usize) usize {
    assert(index < distances_m.len);
    if (index == 0) return 0;
    const target_m = distances_m[index] - slope_window_half_m;
    // The first index in [0, index) past the target; the one before it is the answer.
    const past = std.sort.partitionPoint(f64, distances_m[0..index], target_m, less_or_equal);
    return if (past > 0) past - 1 else 0;
}

/// Returns the first index after `index` at least `slope_window_half_m` ahead of it, or the
/// last index.
fn index_ahead(distances_m: []const f64, index: usize) usize {
    assert(index < distances_m.len);
    const target_m = distances_m[index] + slope_window_half_m;
    const after = distances_m[index + 1 ..];
    const found = index + 1 + std.sort.partitionPoint(f64, after, target_m, less);
    return if (found < distances_m.len) found else distances_m.len - 1;
}

fn less_or_equal(target: f64, value: f64) bool {
    return value <= target;
}

fn less(target: f64, value: f64) bool {
    return value < target;
}

test "median_smooth: rejects a single spike" {
    const points = [_][3]f64{
        .{ 0.0, 0.0000, 100.0 },
        .{ 0.0, 0.0001, 101.0 },
        .{ 0.0, 0.0002, 140.0 },
        .{ 0.0, 0.0003, 102.0 },
        .{ 0.0, 0.0004, 103.0 },
    };
    const distances_m = try distances_cumulative(testing.allocator, &points);
    defer testing.allocator.free(distances_m);
    const smoothed_m = try median_smooth(testing.allocator, &points, distances_m, 50.0);
    defer testing.allocator.free(smoothed_m);
    try testing.expectEqual(@as(f64, 102.0), smoothed_m[2]);
}

test "median_smooth: a zero radius keeps each point's own elevation" {
    const points = [_][3]f64{ .{ 0.0, 0.0, 100.0 }, .{ 0.0, 0.001, 140.0 }, .{ 0.0, 0.002, 90.0 } };
    const distances_m = try distances_cumulative(testing.allocator, &points);
    defer testing.allocator.free(distances_m);
    const smoothed_m = try median_smooth(testing.allocator, &points, distances_m, 0.0);
    defer testing.allocator.free(smoothed_m);
    try testing.expectEqualSlices(f64, &.{ 100.0, 140.0, 90.0 }, smoothed_m);
}

test "median_smooth: the window is capped on points logged in place" {
    // 600 points at the same spot: every window would hold all 600 without the cap.
    var points: [600][3]f64 = undefined;
    for (&points, 0..) |*point, index| point.* = .{ 45.0, 6.0, @floatFromInt(index % 7) };
    const distances_m = try distances_cumulative(testing.allocator, &points);
    defer testing.allocator.free(distances_m);
    const smoothed_m = try median_smooth(testing.allocator, &points, distances_m, 15.0);
    defer testing.allocator.free(smoothed_m);
    for (smoothed_m) |elevation_m| try testing.expect(elevation_m >= 0 and elevation_m <= 6);
}

test "median: odd and even counts" {
    var odd = [_]f64{ 3.0, 1.0, 2.0 };
    try testing.expectEqual(@as(f64, 2.0), median(&odd));
    var even = [_]f64{ 4.0, 1.0, 3.0, 2.0 };
    try testing.expectEqual(@as(f64, 2.5), median(&even));
    var one = [_]f64{7.0};
    try testing.expectEqual(@as(f64, 7.0), median(&one));
}

test "gain_loss_accumulate: a flat noisy signal has no gain" {
    const elevations_m = [_]f64{ 100.0, 101.5, 99.0, 100.5, 98.5, 101.0, 99.5, 100.0 };
    var gain_loss = try gain_loss_accumulate(testing.allocator, &elevations_m, 3.0);
    defer gain_loss.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0), gain_loss.gain_m_total);
    try testing.expectEqual(@as(f64, 0), gain_loss.loss_m_total);
}

test "gain_loss_accumulate: a clean climb counts in full" {
    const elevations_m = [_]f64{ 0.0, 10.0, 20.0, 30.0, 40.0, 50.0 };
    var gain_loss = try gain_loss_accumulate(testing.allocator, &elevations_m, 3.0);
    defer gain_loss.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 50), gain_loss.gain_m_total);
    try testing.expectEqual(@as(f64, 0), gain_loss.loss_m_total);
}

test "gain_loss_accumulate: sub-threshold steps undercount by at most the threshold" {
    const elevations_m = [_]f64{ 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    var gain_loss = try gain_loss_accumulate(testing.allocator, &elevations_m, 3.0);
    defer gain_loss.deinit(testing.allocator);
    try testing.expect(gain_loss.gain_m_total >= 6.0 - 3.0 and gain_loss.gain_m_total <= 6.0);
}

test "gain_loss_accumulate: a noisy climb stays close to the true gain" {
    const elevations_m = [_]f64{ 0.0, 9.0, 11.0, 19.0, 21.0, 29.0, 31.0, 40.0 };
    var gain_loss = try gain_loss_accumulate(testing.allocator, &elevations_m, 3.0);
    defer gain_loss.deinit(testing.allocator);
    try testing.expect(gain_loss.gain_m_total >= 36.0 and gain_loss.gain_m_total <= 40.0);
    try testing.expectEqual(@as(f64, 0), gain_loss.loss_m_total);
}

test "gain_loss_accumulate: the cumulative arrays never decrease and end at the totals" {
    const elevations_m = [_]f64{ 0.0, 10.0, 5.0, 15.0, 0.0 };
    var gain_loss = try gain_loss_accumulate(testing.allocator, &elevations_m, 3.0);
    defer gain_loss.deinit(testing.allocator);
    const gains = gain_loss.gains_m_cumulative;
    const losses = gain_loss.losses_m_cumulative;
    for (1..gains.len) |index| {
        try testing.expect(gains[index] >= gains[index - 1]);
        try testing.expect(losses[index] >= losses[index - 1]);
    }
    try testing.expectEqual(gain_loss.gain_m_total, gains[gains.len - 1]);
    try testing.expectEqual(gain_loss.loss_m_total, losses[losses.len - 1]);
}

test "gain_loss_accumulate: a change of exactly the threshold doesn't count" {
    const elevations_m = [_]f64{ 0.0, 3.0, 0.0 };
    var gain_loss = try gain_loss_accumulate(testing.allocator, &elevations_m, 3.0);
    defer gain_loss.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0), gain_loss.gain_m_total);
    try testing.expectEqual(@as(f64, 0), gain_loss.loss_m_total);
}

test "gain_loss_compute: a spike inflates neither gain nor loss" {
    const points = [_][3]f64{
        .{ 0.0, 0.0000, 100.0 },
        .{ 0.0, 0.0001, 100.0 },
        .{ 0.0, 0.0002, 145.0 },
        .{ 0.0, 0.0003, 100.0 },
        .{ 0.0, 0.0004, 100.0 },
    };
    var gain_loss = try gain_loss_compute(testing.allocator, &points, 50.0, 3.0);
    defer gain_loss.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0), gain_loss.gain_m_total);
    try testing.expectEqual(@as(f64, 0), gain_loss.loss_m_total);
}

test "gain_loss_compute: 0 and 1 points" {
    const point = [_][3]f64{.{ 45.0, 6.0, 1000.0 }};
    for (0..2) |count| {
        var gain_loss = try gain_loss_compute(testing.allocator, point[0..count], 15.0, 3.0);
        defer gain_loss.deinit(testing.allocator);
        try testing.expectEqual(count, gain_loss.gains_m_cumulative.len);
        try testing.expectEqual(@as(f64, 0), gain_loss.gain_m_total);
    }
}

test "slopes_compute: a steady climb has a steady grade" {
    // About 111 m apart on the equator, 10 m higher each time: about 9%.
    const points = [_][3]f64{
        .{ 0.0, 0.000, 0.0 },
        .{ 0.0, 0.001, 10.0 },
        .{ 0.0, 0.002, 20.0 },
        .{ 0.0, 0.003, 30.0 },
        .{ 0.0, 0.004, 40.0 },
    };
    const distances_m = try distances_cumulative(testing.allocator, &points);
    defer testing.allocator.free(distances_m);
    const slopes = try slopes_compute(testing.allocator, &points, distances_m);
    defer testing.allocator.free(slopes);
    try testing.expectEqual(points.len, slopes.len);
    for (slopes) |slope| try testing.expectApproxEqAbs(9.0, slope, 0.1);
}

test "slopes_compute: a flat profile has zero grade" {
    const points = [_][3]f64{
        .{ 0.0, 0.000, 100.0 },
        .{ 0.0, 0.001, 100.0 },
        .{ 0.0, 0.002, 100.0 },
    };
    const distances_m = try distances_cumulative(testing.allocator, &points);
    defer testing.allocator.free(distances_m);
    const slopes = try slopes_compute(testing.allocator, &points, distances_m);
    defer testing.allocator.free(slopes);
    for (slopes) |slope| try testing.expectEqual(@as(f64, 0), slope);
}

test "slopes_compute: a lone spike on a flat trail doesn't read as steep" {
    // About 11 m apart; unsmoothed, a 5 m spike over a 10 m window would read as 45%.
    const points = [_][3]f64{
        .{ 0.0, 0.0000, 100.0 },
        .{ 0.0, 0.0001, 100.0 },
        .{ 0.0, 0.0002, 105.0 },
        .{ 0.0, 0.0003, 100.0 },
        .{ 0.0, 0.0004, 100.0 },
        .{ 0.0, 0.0005, 100.0 },
        .{ 0.0, 0.0006, 100.0 },
    };
    const distances_m = try distances_cumulative(testing.allocator, &points);
    defer testing.allocator.free(distances_m);
    const slopes = try slopes_compute(testing.allocator, &points, distances_m);
    defer testing.allocator.free(slopes);
    for (slopes) |slope| try testing.expect(@abs(slope) < 20.0);
}

test "slopes_compute: 0 points, and points in one place" {
    const empty = try slopes_compute(testing.allocator, &.{}, &.{});
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const points = [_][3]f64{ .{ 45.0, 6.0, 100.0 }, .{ 45.0, 6.0, 120.0 } };
    const distances_m = try distances_cumulative(testing.allocator, &points);
    defer testing.allocator.free(distances_m);
    const slopes = try slopes_compute(testing.allocator, &points, distances_m);
    defer testing.allocator.free(slopes);
    try testing.expectEqualSlices(f64, &.{ 0, 0 }, slopes);
}

test "index_behind and index_ahead: reach at least the half window, or stop at the ends" {
    const distances_m = [_]f64{ 0, 5, 10, 20, 30, 40, 45 };
    try testing.expectEqual(@as(usize, 0), index_behind(&distances_m, 0));
    try testing.expectEqual(@as(usize, 0), index_behind(&distances_m, 2));
    try testing.expectEqual(@as(usize, 2), index_behind(&distances_m, 4));
    try testing.expectEqual(@as(usize, 4), index_ahead(&distances_m, 2));
    try testing.expectEqual(@as(usize, 6), index_ahead(&distances_m, 5));
    try testing.expectEqual(@as(usize, 6), index_ahead(&distances_m, 6));
}

test "slope_percent_net: net climb over distance, 0 over no distance" {
    try testing.expectEqual(@as(f64, 5.0), slope_percent_net(80.0, 30.0, 1000.0));
    try testing.expectEqual(@as(f64, -2.0), slope_percent_net(0.0, 20.0, 1000.0));
    try testing.expectEqual(@as(f64, 0.0), slope_percent_net(10.0, 0.0, 0.0));
}
