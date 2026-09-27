//! Pace, fatigue, circadian and weather accumulated point by point over a range of a trace.
//! Sections and stages both run this loop; they differ only in which waypoints bound a range.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Trace = @import("trace.zig").Trace;
const pace_model = @import("pace_model.zig");

pub const SegmentMetrics = struct {
    elevation_m_min: f64,
    elevation_m_max: f64,
    /// The steepest grade, up or down.
    slope_percent_max: f64,
    /// Moving time.
    duration_s: f64,
    /// Σ distance × terrain factor: divided by the distance, the average pace factor.
    distance_m_weighted_terrain: f64,
    /// Σ distance × combined factor: divided by the distance, the average effort factor.
    distance_m_weighted_combined: f64,
};

/// What stays fixed while the model runs over consecutive ranges.
pub const Model = struct {
    pace_s_per_km: f64,
    fatigue_coefficient: f64,
    /// The race start epoch, or null for a neutral circadian factor.
    clock_start_s: ?i64,
};

/// What the model carries from one range to the next, so fatigue and the circadian clock
/// reflect everything run before.
pub const Progress = struct {
    distance_m_effort: f64 = 0.0,
    /// Kept in f64 and truncated only when the circadian model reads it, so the clock drifts
    /// less than a second over a whole race.
    elapsed_s: f64 = 0.0,
};

/// Accumulates the metrics over the steps from point `index_start` to point `index_end`, and
/// advances `progress` past them. `weather` is the forecast for the range, constant across
/// it: one forecast per checkpoint.
pub fn metrics_compute(
    trace: *const Trace,
    index_start: usize,
    index_end: usize,
    model: Model,
    weather: pace_model.WeatherConditions,
    progress: *Progress,
) SegmentMetrics {
    assert(index_start <= index_end);
    assert(index_end < trace.points.len);
    assert(model.pace_s_per_km > 0);
    const progress_before = progress.*;

    var metrics: SegmentMetrics = .{
        .elevation_m_min = trace.points[index_start][2],
        .elevation_m_max = trace.points[index_start][2],
        .slope_percent_max = 0.0,
        .duration_s = 0.0,
        .distance_m_weighted_terrain = 0.0,
        .distance_m_weighted_combined = 0.0,
    };
    const weather_factor = pace_model.weather_factor(weather);
    for (index_start..index_end) |index| {
        const elevation_m = trace.points[index][2];
        metrics.elevation_m_min = @min(metrics.elevation_m_min, elevation_m);
        metrics.elevation_m_max = @max(metrics.elevation_m_max, elevation_m);
        const slope_percent = @abs(trace.slopes_percent[index]);
        metrics.slope_percent_max = @max(metrics.slope_percent_max, slope_percent);

        const step_m = trace.distances_m_cumulative[index + 1] -
            trace.distances_m_cumulative[index];
        const factors = pace_model.factors_compute(
            trace.slopes_percent[index] / 100.0,
            progress.distance_m_effort / 1000.0,
            model.fatigue_coefficient,
            model.clock_start_s,
            progress.elapsed_s,
            weather_factor,
        );
        const step_s = (step_m / 1000.0) * model.pace_s_per_km * factors.combined;

        metrics.duration_s += step_s;
        metrics.distance_m_weighted_terrain += step_m * factors.terrain;
        metrics.distance_m_weighted_combined += step_m * factors.combined;
        progress.elapsed_s += step_s;
        progress.distance_m_effort += step_m * factors.terrain;
    }
    assert(metrics.duration_s >= 0);
    assert(progress.elapsed_s >= progress_before.elapsed_s);
    assert(progress.distance_m_effort >= progress_before.distance_m_effort);
    return metrics;
}

const flat_points = [_][3]f64{
    .{ 0.0, 0.000, 100.0 },
    .{ 0.0, 0.001, 100.0 },
    .{ 0.0, 0.002, 100.0 },
    .{ 0.0, 0.003, 100.0 },
};

const weather_neutral = pace_model.weather_neutral;

const model_default: Model = .{
    .pace_s_per_km = pace_model.pace_base_s_per_km_default,
    .fatigue_coefficient = pace_model.fatigue_coefficient_default,
    .clock_start_s = null,
};

test "metrics_compute: flat terrain has a neutral pace factor" {
    var trace = try Trace.init(testing.allocator, &flat_points);
    defer trace.deinit(testing.allocator);

    var progress: Progress = .{};
    const last = trace.points.len - 1;
    const metrics = metrics_compute(&trace, 0, last, model_default, weather_neutral, &progress);
    try testing.expectEqual(@as(f64, 100.0), metrics.elevation_m_min);
    try testing.expectEqual(@as(f64, 100.0), metrics.elevation_m_max);
    // On flat terrain the terrain-weighted distance is the distance.
    const distance_m = trace.distances_m_cumulative[last];
    try testing.expectApproxEqAbs(distance_m, metrics.distance_m_weighted_terrain, 1e-6);
    try testing.expect(metrics.duration_s > 0.0);
    try testing.expectEqual(metrics.duration_s, progress.elapsed_s);
}

test "metrics_compute: an empty range changes nothing" {
    var trace = try Trace.init(testing.allocator, &flat_points);
    defer trace.deinit(testing.allocator);

    var progress: Progress = .{ .distance_m_effort = 5.0, .elapsed_s = 7.0 };
    const metrics = metrics_compute(&trace, 2, 2, model_default, weather_neutral, &progress);
    try testing.expectEqual(@as(f64, 0), metrics.duration_s);
    try testing.expectEqual(Progress{ .distance_m_effort = 5.0, .elapsed_s = 7.0 }, progress);
}

test "metrics_compute: progress carries across consecutive ranges" {
    var points: [20][3]f64 = undefined;
    for (&points, 0..) |*point, index| {
        const t = @as(f64, @floatFromInt(index)) / 20.0;
        point.* = .{ 0.0, t * 0.01, 100.0 + t * 200.0 };
    }
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);

    const last = trace.points.len - 1;
    const middle = last / 2;
    var progress: Progress = .{};
    const first = metrics_compute(&trace, 0, middle, model_default, weather_neutral, &progress);
    const effort_after_first = progress.distance_m_effort;
    const second = metrics_compute(&trace, middle, last, model_default, weather_neutral, &progress);

    try testing.expect(progress.distance_m_effort > effort_after_first);
    try testing.expectApproxEqAbs(first.duration_s + second.duration_s, progress.elapsed_s, 1e-9);
}

test "metrics_compute: bad weather slows by exactly its factor" {
    var trace = try Trace.init(testing.allocator, &flat_points);
    defer trace.deinit(testing.allocator);
    const hot: pace_model.WeatherConditions = .{
        .temperature_c = 32.0,
        .humidity_percent = 85.0,
        .wind_kmh = 35.0,
        .precipitation_probability_percent = 80.0,
    };

    const last = trace.points.len - 1;
    var progress_neutral: Progress = .{};
    const neutral = metrics_compute(
        &trace,
        0,
        last,
        model_default,
        weather_neutral,
        &progress_neutral,
    );
    var progress_hot: Progress = .{};
    const adverse = metrics_compute(&trace, 0, last, model_default, hot, &progress_hot);

    const expected_s = neutral.duration_s * pace_model.weather_factor(hot);
    try testing.expectApproxEqAbs(expected_s, adverse.duration_s, 1e-6);
    // Weather slows the runner but doesn't add effort distance: that is terrain only.
    const terrain_neutral = neutral.distance_m_weighted_terrain;
    try testing.expectApproxEqAbs(terrain_neutral, adverse.distance_m_weighted_terrain, 1e-9);
}
