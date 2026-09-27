//! Audio frames for terminus's sonification of a route: each trace point becomes a frame of
//! normalized parameters that drive oscillators, filters and spatialization.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const AudioFrame = struct {
    /// Uniform in the point index, from 0 to 1: every point gets the same playback time.
    position: f32,
    /// Cumulative distance over total distance.
    distance_normalized: f32,
    /// Elevation over the route's range → oscillator frequency and reverb mix.
    pitch: f32,
    /// |slope| over the steepest → gain.
    intensity: f32,
    /// Signed slope: 0 steep descent, 0.5 flat, 1 steep climb → filter Q.
    timbre: f32,
    /// The section's bearing, not normalized → HRTF position.
    bearing_degrees: f32,
    /// The section's pace: 0 fastest, 1 slowest → tremolo rate.
    pace_normalized: f32,
};

/// Per-point inputs, all the same length.
pub const Inputs = struct {
    elevations_m: []const f64,
    /// Cumulative, as `Trace.distances_m_cumulative`.
    distances_m: []const f64,
    /// Smoothed, as `Trace.slopes_percent`.
    slopes_percent: []const f64,
    /// The bearing of each point's section, or 0 without sections.
    bearings_degrees: []const f64,
    /// The pace of each point's section, or 0 without sections.
    paces_s_per_m: []const f64,

    fn count(inputs: *const Inputs) usize {
        const length = inputs.elevations_m.len;
        assert(inputs.distances_m.len == length);
        assert(inputs.slopes_percent.len == length);
        assert(inputs.bearings_degrees.len == length);
        assert(inputs.paces_s_per_m.len == length);
        return length;
    }
};

/// The denominators that normalize each parameter. A flat or empty range becomes 1, so a
/// flat route doesn't divide by zero.
const Ranges = struct {
    elevation_m_min: f64,
    elevation_m_range: f64,
    slope_percent_range: f64,
    /// Zero paces (no section data) are left out; without any, every frame is mid-pace.
    pace_known: bool,
    pace_s_per_m_min: f64,
    pace_s_per_m_range: f64,
    distance_m_total: f64,
};

/// Returns one frame per point. The caller owns the result.
pub fn audio_frames_generate(
    allocator: std.mem.Allocator,
    inputs: *const Inputs,
) ![]AudioFrame {
    const count = inputs.count();
    const frames = try allocator.alloc(AudioFrame, count);
    if (count == 0) return frames;

    const ranges = ranges_compute(inputs);
    for (frames, 0..) |*frame, index| {
        const slope = inputs.slopes_percent[index];
        const pace_s_per_m = inputs.paces_s_per_m[index];
        const pace: f64 = if (ranges.pace_known and pace_s_per_m > 0.0)
            (pace_s_per_m - ranges.pace_s_per_m_min) / ranges.pace_s_per_m_range
        else
            0.5;
        const position: f64 = if (count > 1)
            @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count - 1))
        else
            0.0;
        const distance: f64 = if (ranges.distance_m_total > 0.0)
            inputs.distances_m[index] / ranges.distance_m_total
        else
            0.0;
        const elevation_m = inputs.elevations_m[index];
        const timbre = std.math.clamp((slope / ranges.slope_percent_range) * 0.5 + 0.5, 0.0, 1.0);
        frame.* = .{
            .position = @floatCast(position),
            .distance_normalized = @floatCast(distance),
            .pitch = @floatCast((elevation_m - ranges.elevation_m_min) / ranges.elevation_m_range),
            .intensity = @floatCast(@abs(slope) / ranges.slope_percent_range),
            .timbre = @floatCast(timbre),
            .bearing_degrees = @floatCast(inputs.bearings_degrees[index]),
            .pace_normalized = @floatCast(std.math.clamp(pace, 0.0, 1.0)),
        };
        assert(frame.pitch >= 0.0 and frame.pitch <= 1.0);
        assert(frame.intensity >= 0.0 and frame.intensity <= 1.0);
    }
    return frames;
}

fn ranges_compute(inputs: *const Inputs) Ranges {
    assert(inputs.count() > 0);
    const elevation_m_min = std.mem.min(f64, inputs.elevations_m);
    const elevation_m_max = std.mem.max(f64, inputs.elevations_m);
    var slope_percent_max: f64 = 0.0;
    for (inputs.slopes_percent) |slope| slope_percent_max = @max(slope_percent_max, @abs(slope));

    var pace_min: f64 = std.math.floatMax(f64);
    var pace_max: f64 = 0.0;
    for (inputs.paces_s_per_m) |pace| {
        if (pace <= 0.0) continue;
        pace_min = @min(pace_min, pace);
        pace_max = @max(pace_max, pace);
    }
    const pace_known = pace_max > 0.0;

    const ranges: Ranges = .{
        .elevation_m_min = elevation_m_min,
        .elevation_m_range = if (elevation_m_max > elevation_m_min)
            elevation_m_max - elevation_m_min
        else
            1.0,
        .slope_percent_range = if (slope_percent_max > 0.0) slope_percent_max else 1.0,
        .pace_known = pace_known,
        .pace_s_per_m_min = if (pace_known) pace_min else 0.0,
        .pace_s_per_m_range = if (pace_known and pace_max > pace_min) pace_max - pace_min else 1.0,
        .distance_m_total = inputs.distances_m[inputs.distances_m.len - 1],
    };
    assert(ranges.elevation_m_range > 0 and ranges.slope_percent_range > 0);
    assert(ranges.pace_s_per_m_range > 0);
    return ranges;
}

fn generate_test(
    elevations_m: []const f64,
    distances_m: []const f64,
    slopes_percent: []const f64,
    bearings_degrees: []const f64,
    paces_s_per_m: []const f64,
) ![]AudioFrame {
    return audio_frames_generate(testing.allocator, &.{
        .elevations_m = elevations_m,
        .distances_m = distances_m,
        .slopes_percent = slopes_percent,
        .bearings_degrees = bearings_degrees,
        .paces_s_per_m = paces_s_per_m,
    });
}

test "audio_frames_generate: 0 and 1 points" {
    const empty = try generate_test(&.{}, &.{}, &.{}, &.{}, &.{});
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const one = try generate_test(&.{500.0}, &.{0.0}, &.{0.0}, &.{0.0}, &.{0.0});
    defer testing.allocator.free(one);
    try testing.expectEqual(AudioFrame{
        .position = 0.0,
        .distance_normalized = 0.0,
        .pitch = 0.0,
        .intensity = 0.0,
        .timbre = 0.5,
        .bearing_degrees = 0.0,
        .pace_normalized = 0.5,
    }, one[0]);
}

test "audio_frames_generate: every parameter stays normalized" {
    const frames = try generate_test(
        &.{ 100.0, 200.0, 300.0, 250.0, 150.0 },
        &.{ 0.0, 1000.0, 2000.0, 3000.0, 4000.0 },
        &.{ 0.0, 5.0, 10.0, -5.0, -8.0 },
        &.{ 45.0, 45.0, 90.0, 180.0, 270.0 },
        &.{ 0.60, 0.72, 0.90, 0.48, 0.54 },
    );
    defer testing.allocator.free(frames);
    for (frames) |frame| {
        const values = [_]f32{
            frame.position,  frame.distance_normalized, frame.pitch,
            frame.intensity, frame.timbre,              frame.pace_normalized,
        };
        for (values) |value| try testing.expect(value >= 0.0 and value <= 1.0);
    }
}

test "audio_frames_generate: pitch and distance span the route, position is uniform" {
    const frames = try generate_test(
        &.{ 100.0, 200.0, 300.0, 400.0, 500.0 },
        &.{ 0.0, 100.0, 500.0, 900.0, 1000.0 },
        &.{ 0.0, 1.0, 2.0, 3.0, 4.0 },
        &.{ 0.0, 0.0, 0.0, 0.0, 0.0 },
        &.{ 0.0, 0.0, 0.0, 0.0, 0.0 },
    );
    defer testing.allocator.free(frames);
    const positions = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    const distances = [_]f32{ 0.0, 0.1, 0.5, 0.9, 1.0 };
    for (frames, positions, distances) |frame, position, distance| {
        try testing.expectApproxEqAbs(position, frame.position, 1e-6);
        try testing.expectApproxEqAbs(distance, frame.distance_normalized, 1e-6);
        try testing.expectApproxEqAbs(position, frame.pitch, 1e-6);
    }
}

test "audio_frames_generate: a flat route is silent, neutral and mid-pace" {
    const frames = try generate_test(
        &.{ 200.0, 200.0, 200.0 },
        &.{ 0.0, 1000.0, 2000.0 },
        &.{ 0.0, 0.0, 0.0 },
        &.{ 90.0, 90.0, 90.0 },
        &.{ 0.0, 0.0, 0.0 },
    );
    defer testing.allocator.free(frames);
    for (frames) |frame| {
        try testing.expectEqual(@as(f32, 0.0), frame.pitch);
        try testing.expectEqual(@as(f32, 0.0), frame.intensity);
        try testing.expectEqual(@as(f32, 0.5), frame.timbre);
        try testing.expectEqual(@as(f32, 0.5), frame.pace_normalized);
        try testing.expectEqual(@as(f32, 90.0), frame.bearing_degrees);
    }
}

test "audio_frames_generate: intensity and timbre follow the slope" {
    const frames = try generate_test(
        &.{ 100.0, 150.0, 250.0, 220.0, 200.0 },
        &.{ 0.0, 500.0, 1000.0, 1500.0, 2000.0 },
        &.{ 0.0, 5.0, 20.0, -6.0, -20.0 },
        &.{ 0.0, 0.0, 0.0, 0.0, 0.0 },
        &.{ 0.0, 0.0, 0.0, 0.0, 0.0 },
    );
    defer testing.allocator.free(frames);
    try testing.expectEqual(@as(f32, 1.0), frames[2].intensity);
    try testing.expectEqual(@as(f32, 1.0), frames[4].intensity);
    try testing.expectEqual(@as(f32, 0.5), frames[0].timbre);
    try testing.expect(frames[1].timbre > 0.5);
    try testing.expect(frames[3].timbre < 0.5);
    try testing.expectEqual(@as(f32, 1.0), frames[2].timbre);
    try testing.expectEqual(@as(f32, 0.0), frames[4].timbre);
}

test "audio_frames_generate: pace spans the fastest to the slowest section" {
    const frames = try generate_test(
        &.{ 100.0, 200.0, 300.0, 200.0 },
        &.{ 0.0, 1000.0, 2000.0, 3000.0 },
        &.{ 0.0, 5.0, 5.0, -5.0 },
        &.{ 0.0, 90.0, 270.0, 0.0 },
        &.{ 0.3, 0.3, 0.6, 0.0 },
    );
    defer testing.allocator.free(frames);
    try testing.expectEqual(@as(f32, 0.0), frames[0].pace_normalized);
    try testing.expectEqual(@as(f32, 1.0), frames[2].pace_normalized);
    // A point without section data is mid-pace.
    try testing.expectEqual(@as(f32, 0.5), frames[3].pace_normalized);
    try testing.expectEqual(@as(f32, 270.0), frames[2].bearing_degrees);
}
