//! Peaks and valleys of an elevation profile: AMPD (automatic multiscale-based peak detection,
//! Scholkmann et al. 2012), then clustering of adjacent candidates, then a prominence filter.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const Kind = enum { peak, valley };

/// The widest scale AMPD compares at, in points on each side.
const scale_max = 21;
/// How many scales must agree before a point is a candidate.
const scales_agreeing_min = 15;
/// Candidates closer than this many points are one extremum; the most extreme one stays.
const cluster_window = 3;
/// An extremum must stand this many meters above (or below) its key col to count.
const prominence_min_m = 20.0;
/// Points compared per vector operation.
const vector_length = 8;

comptime {
    assert(scales_agreeing_min > 0);
    assert(scales_agreeing_min <= scale_max);
    // Scale counts are stored in a u8.
    assert(scale_max <= std.math.maxInt(u8));
}

/// Returns the indices, ascending, of the peaks in `signal`. The caller owns the result.
pub fn find_peaks(allocator: std.mem.Allocator, signal: []const f32) ![]usize {
    return find(allocator, signal, .peak);
}

/// Returns the indices, ascending, of the valleys in `signal`. The caller owns the result.
pub fn find_valleys(allocator: std.mem.Allocator, signal: []const f32) ![]usize {
    return find(allocator, signal, .valley);
}

fn find(allocator: std.mem.Allocator, signal: []const f32, kind: Kind) ![]usize {
    // With fewer than 3 points no point has a neighbor on each side.
    if (signal.len < 3) return allocator.alloc(usize, 0);

    const raw = try ampd_candidates(allocator, signal, scale_max, scales_agreeing_min, kind);
    defer allocator.free(raw);
    const clustered = try cluster(allocator, raw, signal, kind);
    defer allocator.free(clustered);
    const kept = try prominence_filter(allocator, clustered, signal, prominence_min_m, kind);

    assert(kept.len <= clustered.len);
    assert(std.sort.isSorted(usize, kept, {}, std.sort.asc(usize)));
    return kept;
}

/// Returns the points that beat both neighbors `scale` points away at `agreeing_min` or more
/// of the scales 1 to `scales_max`. The caller owns the result.
fn ampd_candidates(
    allocator: std.mem.Allocator,
    signal: []const f32,
    scales_max: u8,
    agreeing_min: u8,
    kind: Kind,
) ![]usize {
    assert(signal.len >= 3);
    assert(agreeing_min > 0 and agreeing_min <= scales_max);

    // One count per point, not a scale × point boolean scalogram: for 10k points at 21
    // scales that's 10 KB instead of 210 KB, which fits in L1 and needs no second pass.
    const counts = try allocator.alloc(u8, signal.len);
    defer allocator.free(counts);
    @memset(counts, 0);

    const scale_last: usize = @min(scales_max, signal.len / 2);
    for (1..scale_last + 1) |scale| {
        if (scale * 2 >= signal.len) break;
        scale_count(signal, counts, scale, kind);
    }

    var candidates: std.ArrayList(usize) = .empty;
    defer candidates.deinit(allocator);
    for (counts, 0..) |count, index| {
        assert(count <= scales_max);
        if (count >= agreeing_min) try candidates.append(allocator, index);
    }
    return candidates.toOwnedSlice(allocator);
}

/// Adds 1 to `counts[i]` for each point that beats both neighbors `scale` points away.
fn scale_count(signal: []const f32, counts: []u8, scale: usize, kind: Kind) void {
    assert(scale >= 1);
    assert(scale * 2 < signal.len);
    assert(counts.len == signal.len);
    const Vector = @Vector(vector_length, f32);

    var index: usize = scale;
    while (index + vector_length + scale <= signal.len) : (index += vector_length) {
        const center: Vector = signal[index..][0..vector_length].*;
        const left: Vector = signal[index - scale ..][0..vector_length].*;
        const right: Vector = signal[index + scale ..][0..vector_length].*;
        const beats_left = if (kind == .peak) center > left else center < left;
        const beats_right = if (kind == .peak) center > right else center < right;
        const none: @Vector(vector_length, bool) = @splat(false);
        const beats_both = @select(bool, beats_left, beats_right, none);
        inline for (0..vector_length) |lane| {
            if (beats_both[lane]) counts[index + lane] += 1;
        }
    }
    // The points left over after the last full vector.
    while (index < signal.len - scale) : (index += 1) {
        const value = signal[index];
        const beats_both = switch (kind) {
            .peak => value > signal[index - scale] and value > signal[index + scale],
            .valley => value < signal[index - scale] and value < signal[index + scale],
        };
        if (beats_both) counts[index] += 1;
    }
}

/// Merges runs of candidates no more than `cluster_window` points apart, keeping the most
/// extreme point of each run. The caller owns the result.
fn cluster(
    allocator: std.mem.Allocator,
    candidates: []const usize,
    signal: []const f32,
    kind: Kind,
) ![]usize {
    if (candidates.len == 0) return allocator.alloc(usize, 0);
    assert(candidates[candidates.len - 1] < signal.len);

    var clustered: std.ArrayList(usize) = .empty;
    defer clustered.deinit(allocator);
    var best = candidates[0];
    for (candidates[1..], candidates[0 .. candidates.len - 1]) |index, previous| {
        assert(index > previous);
        if (index - previous <= cluster_window) {
            if (more_extreme(signal[index], signal[best], kind)) best = index;
        } else {
            try clustered.append(allocator, best);
            best = index;
        }
    }
    try clustered.append(allocator, best);

    assert(clustered.items.len <= candidates.len);
    return clustered.toOwnedSlice(allocator);
}

fn more_extreme(value: f32, than: f32, kind: Kind) bool {
    return switch (kind) {
        .peak => value > than,
        .valley => value < than,
    };
}

/// Returns how far the extremum at `index` stands out from the higher of its two key cols
/// (for a peak), or below the lower of its two cols (for a valley). Each side walks out
/// until the signal passes the extremum's value or the signal ends.
fn prominence(signal: []const f32, index: usize, kind: Kind) f32 {
    assert(index < signal.len);
    const value = signal[index];

    var col_left = value;
    var left = index;
    while (left > 0) {
        left -= 1;
        if (more_extreme(signal[left], value, kind)) break;
        if (more_extreme(col_left, signal[left], kind)) col_left = signal[left];
    }
    var col_right = value;
    var right = index;
    while (right + 1 < signal.len) {
        right += 1;
        if (more_extreme(signal[right], value, kind)) break;
        if (more_extreme(col_right, signal[right], kind)) col_right = signal[right];
    }

    const result = switch (kind) {
        .peak => value - @max(col_left, col_right),
        .valley => @min(col_left, col_right) - value,
    };
    assert(result >= 0);
    return result;
}

/// Keeps the candidates at least `min` prominent. The caller owns the result.
fn prominence_filter(
    allocator: std.mem.Allocator,
    candidates: []const usize,
    signal: []const f32,
    min: f32,
    kind: Kind,
) ![]usize {
    assert(min >= 0);
    var kept: std.ArrayList(usize) = .empty;
    defer kept.deinit(allocator);
    for (candidates) |index| {
        if (prominence(signal, index, kind) >= min) try kept.append(allocator, index);
    }
    assert(kept.items.len <= candidates.len);
    return kept.toOwnedSlice(allocator);
}

fn ampd_clustered(
    signal: []const f32,
    scales_max: u8,
    agreeing_min: u8,
    kind: Kind,
) ![]usize {
    const raw = try ampd_candidates(testing.allocator, signal, scales_max, agreeing_min, kind);
    defer testing.allocator.free(raw);
    return cluster(testing.allocator, raw, signal, kind);
}

test "ampd_candidates: a flat signal has no peaks" {
    const signal = [_]f32{ 2.0, 2.0, 2.0, 2.0, 2.0 };
    const peaks = try ampd_clustered(&signal, 2, 1, .peak);
    defer testing.allocator.free(peaks);
    try testing.expectEqual(@as(usize, 0), peaks.len);
}

test "ampd_candidates: scales wider than the signal are skipped" {
    const signal = [_]f32{ 1.0, 5.0, 2.0 };
    const peaks = try ampd_clustered(&signal, 10, 1, .peak);
    defer testing.allocator.free(peaks);
    try testing.expectEqualSlices(usize, &.{1}, peaks);
}

test "ampd_candidates: the vector path and the scalar remainder agree" {
    // 20 points: indices 1 to 16 go through the vector path at scale 1, 17 and 18 through
    // the scalar one. A peak on each side of the boundary must be found.
    var signal: [20]f32 = @splat(0);
    signal[5] = 10;
    signal[18] = 10;
    const peaks = try ampd_clustered(&signal, 1, 1, .peak);
    defer testing.allocator.free(peaks);
    try testing.expectEqualSlices(usize, &.{ 5, 18 }, peaks);
}

test "ampd_candidates: noise near the major peaks clusters to them" {
    const signal = [_]f32{ 1.0, 1.1, 5.0, 4.9, 2.0, 2.1, 1.9, 6.0, 5.9, 1.0 };
    const peaks = try ampd_clustered(&signal, 3, 2, .peak);
    defer testing.allocator.free(peaks);
    try testing.expectEqualSlices(usize, &.{ 2, 7 }, peaks);
}

test "ampd_candidates: more scales agreeing never finds more peaks" {
    const signal = [_]f32{ 1.0, 3.0, 5.0, 3.0, 1.0, 4.0, 6.0, 4.0, 1.0 };
    const single = try ampd_clustered(&signal, 1, 1, .peak);
    defer testing.allocator.free(single);
    const multi = try ampd_clustered(&signal, 3, 3, .peak);
    defer testing.allocator.free(multi);
    try testing.expect(multi.len <= single.len);
}

test "ampd_candidates: valleys are local minima" {
    const signal = [_]f32{ 5.0, 3.0, 1.0, 3.0, 5.0, 2.0, 4.0, 2.0, 5.0 };
    const valleys = try ampd_clustered(&signal, 3, 2, .valley);
    defer testing.allocator.free(valleys);
    try testing.expect(valleys.len > 0);
    for (valleys) |index| {
        try testing.expect(signal[index] < signal[index - 1]);
        try testing.expect(signal[index] < signal[index + 1]);
    }
}

test "ampd_candidates: peaks and valleys mirror on an alternating signal" {
    const signal = [_]f32{ 1.0, 5.0, 1.0, 5.0, 1.0, 5.0, 1.0, 5.0, 1.0 };
    const peaks = try ampd_clustered(&signal, 2, 1, .peak);
    defer testing.allocator.free(peaks);
    const valleys = try ampd_clustered(&signal, 2, 1, .valley);
    defer testing.allocator.free(valleys);
    try testing.expectEqual(peaks.len, valleys.len);
}

test "cluster: keeps the most extreme point of each run" {
    const signal = [_]f32{ 0, 5, 7, 6, 0, 0, 0, 0, 0, 3 };
    const peaks = try cluster(testing.allocator, &.{ 1, 2, 3, 9 }, &signal, .peak);
    defer testing.allocator.free(peaks);
    try testing.expectEqualSlices(usize, &.{ 2, 9 }, peaks);

    const empty = try cluster(testing.allocator, &.{}, &signal, .peak);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "prominence: a peak stands out from the higher of its key cols" {
    const signal = [_]f32{ 0, 50, 100, 60, 40, 55, 70, 30, 0 };
    try testing.expectApproxEqAbs(@as(f32, 30.0), prominence(&signal, 6, .peak), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100.0), prominence(&signal, 2, .peak), 0.001);
}

test "prominence: a valley mirrors a peak" {
    const signal = [_]f32{ 100, 50, 0, 40, 60, 45, 30, 70, 100 };
    try testing.expectApproxEqAbs(@as(f32, 30.0), prominence(&signal, 6, .valley), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100.0), prominence(&signal, 2, .valley), 0.001);
}

test "prominence: an extremum at either end of the signal is 0" {
    // The open side has no col below the extremum, so the higher col is the extremum itself.
    // AMPD never proposes an endpoint, so this never drops a real candidate.
    const signal = [_]f32{ 10, 4, 8 };
    try testing.expectEqual(@as(f32, 0), prominence(&signal, 0, .peak));
    try testing.expectEqual(@as(f32, 0), prominence(&signal, 2, .peak));
}

test "prominence_filter: drops the low-prominence extrema" {
    const signal = [_]f32{ 0, 50, 100, 60, 40, 55, 70, 30, 0 };
    const kept = try prominence_filter(testing.allocator, &.{ 2, 6 }, &signal, 35.0, .peak);
    defer testing.allocator.free(kept);
    try testing.expectEqualSlices(usize, &.{2}, kept);
}

test "prominence_filter: a zero minimum keeps everything" {
    const signal = [_]f32{ 0, 50, 100, 60, 40, 55, 70, 30, 0 };
    const kept = try prominence_filter(testing.allocator, &.{ 2, 6 }, &signal, 0.0, .peak);
    defer testing.allocator.free(kept);
    try testing.expectEqualSlices(usize, &.{ 2, 6 }, kept);
}

test "find_peaks: noise bumps on a mountain are filtered out" {
    var signal: [60]f32 = undefined;
    for (&signal, 0..) |*value, index| {
        const x: f32 = @floatFromInt(index);
        value.* = 200.0 - @abs(x - 30.0) * 6.0 + 2.0 * @sin(x * 1.7);
    }
    const peaks = try find_peaks(testing.allocator, &signal);
    defer testing.allocator.free(peaks);
    try testing.expect(peaks.len >= 1);
    for (peaks) |index| try testing.expect(prominence(&signal, index, .peak) >= prominence_min_m);
}

test "find_peaks and find_valleys: 0, 1 and 2 points have none" {
    const signal = [_]f32{ 1.0, 100.0 };
    for (0..signal.len + 1) |count| {
        const peaks = try find_peaks(testing.allocator, signal[0..count]);
        defer testing.allocator.free(peaks);
        const valleys = try find_valleys(testing.allocator, signal[0..count]);
        defer testing.allocator.free(valleys);
        try testing.expectEqual(@as(usize, 0), peaks.len + valleys.len);
    }
}

test "find_valleys: a flat signal has none" {
    const signal = [_]f32{ 3.0, 3.0, 3.0, 3.0, 3.0 };
    const valleys = try find_valleys(testing.allocator, &signal);
    defer testing.allocator.free(valleys);
    try testing.expectEqual(@as(usize, 0), valleys.len);
}
