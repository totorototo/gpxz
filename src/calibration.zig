//! Interval statistics between boundary waypoints, shared by sections and stages, and live
//! recalibration of the remaining intervals from a runner's real progress.
//!
//! Sections split on every typed waypoint (Start, TimeBarrier, LifeBase, Arrival); stages
//! split on Start, LifeBase and Arrival only. That is the only difference, so `BoundaryKind`
//! captures it and the physics live here once. Legs are separate: they have no boundary type
//! and no cutoff.
//!
//! `intervals_compute` predicts once, when the file loads. `recalibrate` solves the base pace
//! that reproduces the runner's real elapsed time mid-race, then predicts the remaining
//! intervals with it. Only the flat pace moves: slope, fatigue and weather are unchanged, and
//! the circadian clock restarts from the real elapsed time so the night slowdown lands at the
//! right hours.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Trace = @import("trace.zig").Trace;
const Waypoint = @import("gpx_data.zig").Waypoint;
const bearing_to = @import("gps_point.zig").bearing_to;
const pace_model = @import("pace_model.zig");
const segment = @import("segment.zig");
const elevation = @import("elevation.zig");

/// Below this much predicted moving time, actual over predicted is mostly GPS noise, so the
/// calibration factor stays 1.
pub const prediction_s_min = 300.0;

/// The calibration factor is clamped, so one bad GPS fix or a long unplanned stop can't
/// produce an absurd ETA.
pub const calibration_factor_min = 0.5;
pub const calibration_factor_max = 3.0;

pub const BoundaryKind = enum { section, stage };

/// Every field SectionStats and StageStats share: all but the ids (see `WithIds`).
const CommonIntervalStats = struct {
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
    /// The start and end waypoints' `<time>`: the cutoffs.
    epoch_s_start: ?i64,
    epoch_s_end: ?i64,
    bearing_degrees: f64,
    /// From 1 to 5, from the average pace factor; see `difficulty_from_pace_factor`.
    difficulty: u8,
    /// Moving time plus the planned stop at the end checkpoint.
    duration_s_estimated: f64,
    /// The average terrain-only pace factor: 1 is flat-equivalent.
    pace_factor: f64,
    /// The average combined factor (terrain × fatigue × circadian × weather). Minus
    /// `pace_factor`, it is the slowdown that isn't terrain.
    effort_factor: f64,
    /// The time allowed between the two cutoffs, or null without both.
    duration_s_cutoff: ?i64,
    /// Estimated over allowed duration: above 1, the cutoff is missed.
    cutoff_ratio: ?f64,
    /// The planned stop at the end checkpoint, from `<stopDuration>`.
    stop_s: ?u32,
};

/// Returns a struct with `Ids`' fields followed by `CommonIntervalStats`'. SectionStats and
/// StageStats are both built from the one field list, so they can't drift apart.
fn WithIds(comptime Ids: type) type {
    const fields = @typeInfo(Ids).@"struct".fields ++
        @typeInfo(CommonIntervalStats).@"struct".fields;
    comptime var names: [fields.len][:0]const u8 = undefined;
    comptime var types: [fields.len]type = undefined;
    comptime var attributes: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (fields, 0..) |field, index| {
        names[index] = field.name;
        types[index] = field.type;
        attributes[index] = .{
            .@"comptime" = field.is_comptime,
            .@"align" = field.alignment,
            .default_value_ptr = field.default_value_ptr,
        };
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

/// Between two consecutive section boundaries. `stage_index` is the stage it belongs to.
pub const SectionStats = WithIds(struct { section_index: usize, stage_index: usize });

/// Between two consecutive stage boundaries: a group of sections.
pub const StageStats = WithIds(struct { stage_index: usize });

/// A pair of consecutive boundary waypoints resolved onto the trace.
const Range = struct {
    /// The position of the pair among all pairs, counting those that didn't resolve.
    boundary: usize,
    /// The stage the start waypoint belongs to.
    stage_index: usize,
    index_start: usize,
    index_end: usize,
    start: Waypoint,
    end: Waypoint,
};

/// Returns the statistics of each interval between consecutive boundary waypoints of `kind`,
/// or null with fewer than two boundaries. The caller owns the result.
pub fn intervals_compute(
    comptime Stats: type,
    comptime kind: BoundaryKind,
    allocator: std.mem.Allocator,
    trace: *const Trace,
    waypoints: []const Waypoint,
    settings: *const pace_model.Settings,
) !?[]Stats {
    settings.assert_valid();
    const boundaries = try boundaries_collect(allocator, waypoints, kind);
    defer allocator.free(boundaries);
    if (boundaries.len < 2) return null;
    const ranges = try ranges_resolve(allocator, trace, boundaries);
    defer allocator.free(ranges);

    const stats = try allocator.alloc(Stats, ranges.len);
    errdefer allocator.free(stats);
    const model: segment.Model = .{
        .pace_s_per_km = settings.pace_base_s_per_km,
        .fatigue_coefficient = settings.fatigue_coefficient,
        .clock_start_s = boundaries[0].epoch_s,
    };
    // Fatigue and the clock carry across intervals in race order, so each interval pays for
    // the effort before it.
    var progress: segment.Progress = .{};
    assert(stats.len == ranges.len);
    for (ranges, stats) |*range, *entry| {
        const common = interval_stats(trace, range, model, settings, &progress);
        inline for (@typeInfo(CommonIntervalStats).@"struct".fields) |field| {
            @field(entry, field.name) = @field(common, field.name);
        }
        switch (kind) {
            .section => {
                entry.section_index = range.boundary;
                entry.stage_index = range.stage_index;
            },
            .stage => entry.stage_index = range.boundary,
        }
    }
    return stats;
}

/// Returns the waypoints that bound intervals of `kind`, in file order. The caller owns the
/// result.
fn boundaries_collect(
    allocator: std.mem.Allocator,
    waypoints: []const Waypoint,
    kind: BoundaryKind,
) ![]Waypoint {
    var boundaries: std.ArrayList(Waypoint) = .empty;
    defer boundaries.deinit(allocator);
    for (waypoints) |waypoint| {
        const is_boundary = switch (kind) {
            .section => waypoint.is_section_boundary(),
            .stage => waypoint.is_stage_boundary(),
        };
        if (is_boundary) try boundaries.append(allocator, waypoint);
    }
    // Stage boundaries are a subset of section boundaries.
    for (boundaries.items) |*boundary| assert(boundary.is_section_boundary());
    assert(boundaries.items.len <= waypoints.len);
    return boundaries.toOwnedSlice(allocator);
}

/// Resolves each consecutive pair of boundaries onto the trace, in race order. A pair that
/// doesn't resolve, or resolves backwards, is skipped. The caller owns the result.
fn ranges_resolve(
    allocator: std.mem.Allocator,
    trace: *const Trace,
    boundaries: []const Waypoint,
) ![]Range {
    assert(boundaries.len >= 2);
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);

    // Each boundary resolves after the previous one, so a loop course can't snap back to an
    // earlier pass through the same place.
    var search_start: usize = 0;
    var stage_index: usize = 0;
    for (boundaries[0 .. boundaries.len - 1], boundaries[1..], 0..) |start, end, boundary| {
        // A section belongs to the stage opened by the last stage boundary at or before it.
        if (boundary > 0 and start.is_stage_boundary()) stage_index += 1;

        const coordinates_start = [3]f64{ start.latitude, start.longitude, 0.0 };
        const closest_start = trace.closest_point_after(coordinates_start, search_start) orelse
            continue;
        const index_end = index_end_resolve(trace, &end, closest_start.index) orelse continue;
        search_start = index_end;
        if (closest_start.index >= index_end) continue;
        try ranges.append(allocator, .{
            .boundary = boundary,
            .stage_index = stage_index,
            .index_start = closest_start.index,
            .index_end = index_end,
            .start = start,
            .end = end,
        });
    }
    assert(ranges.items.len < boundaries.len);
    return ranges.toOwnedSlice(allocator);
}

/// Returns the trace index of an interval's end waypoint. The Arrival is the end of the
/// trace by definition. A nearest-point search is unreliable there: on a loop course where
/// Start and Arrival share coordinates, it locks onto a match just past the start line.
fn index_end_resolve(trace: *const Trace, end: *const Waypoint, index_start: usize) ?usize {
    assert(trace.points.len > 0);
    assert(index_start < trace.points.len);
    if (end.is_finish()) return trace.points.len - 1;
    const coordinates_end = [3]f64{ end.latitude, end.longitude, 0.0 };
    const closest = trace.closest_point_after(coordinates_end, index_start + 1) orelse
        return null;
    return closest.index;
}

/// Returns one interval's statistics, and advances `progress` past it.
fn interval_stats(
    trace: *const Trace,
    range: *const Range,
    model: segment.Model,
    settings: *const pace_model.Settings,
    progress: *segment.Progress,
) CommonIntervalStats {
    const start = range.index_start;
    const end = range.index_end;
    assert(start < end);
    const distance_m = trace.distances_m_cumulative[end] - trace.distances_m_cumulative[start];
    const gain_m = trace.elevation_gains_m_cumulative[end] -
        trace.elevation_gains_m_cumulative[start];
    const loss_m = trace.elevation_losses_m_cumulative[end] -
        trace.elevation_losses_m_cumulative[start];
    // The weather is the forecast at the checkpoint the runner is heading to.
    const weather = settings.weather.find(range.end.name);
    const metrics = segment.metrics_compute(trace, start, end, model, weather, progress);
    life_base_recover(&range.end, progress);

    const pace_factor = ratio_or_one(metrics.distance_m_weighted_terrain, distance_m);
    const duration_s = metrics.duration_s + stop_s_planned(&range.end, settings.life_base_stop_s);
    assert(duration_s >= metrics.duration_s);
    const duration_s_cutoff = cutoff_duration_s(&range.start, &range.end);
    return .{
        .index_start = start,
        .index_end = end,
        .point_count = @intCast(end - start + 1),
        .point_start = trace.points[start],
        .point_end = trace.points[end],
        .location_start = range.start.name,
        .location_end = range.end.name,
        .distance_m = distance_m,
        .elevation_gain_m = gain_m,
        .elevation_loss_m = loss_m,
        .slope_percent_average = elevation.slope_percent_net(gain_m, loss_m, distance_m),
        .slope_percent_max = metrics.slope_percent_max,
        .elevation_m_min = metrics.elevation_m_min,
        .elevation_m_max = metrics.elevation_m_max,
        .epoch_s_start = range.start.epoch_s,
        .epoch_s_end = range.end.epoch_s,
        .bearing_degrees = bearing_to(
            .{ range.start.latitude, range.start.longitude, 0.0 },
            .{ range.end.latitude, range.end.longitude, 0.0 },
        ),
        .difficulty = difficulty_from_pace_factor(pace_factor),
        .duration_s_estimated = duration_s,
        .pace_factor = pace_factor,
        .effort_factor = ratio_or_one(metrics.distance_m_weighted_combined, distance_m),
        .duration_s_cutoff = duration_s_cutoff,
        .cutoff_ratio = if (duration_s_cutoff) |cutoff_s|
            (if (cutoff_s > 0) duration_s / @as(f64, @floatFromInt(cutoff_s)) else null)
        else
            null,
        .stop_s = range.end.stop_s,
    };
}

/// Returns weighted distance over distance: an average factor, 1 over no distance.
fn ratio_or_one(distance_m_weighted: f64, distance_m: f64) f64 {
    assert(distance_m >= 0);
    return if (distance_m > 0) distance_m_weighted / distance_m else 1.0;
}

/// Returns 1 to 5 from the average pace factor against flat: below 1.1, 1.4, 1.8, 2.5, or
/// above.
pub fn difficulty_from_pace_factor(pace_factor: f64) u8 {
    assert(pace_factor > 0);
    if (pace_factor < 1.1) return 1;
    if (pace_factor < 1.4) return 2;
    if (pace_factor < 1.8) return 3;
    if (pace_factor < 2.5) return 4;
    return 5;
}

fn cutoff_duration_s(start: *const Waypoint, end: *const Waypoint) ?i64 {
    const epoch_s_start = start.epoch_s orelse return null;
    const epoch_s_end = end.epoch_s orelse return null;
    return epoch_s_end - epoch_s_start;
}

fn is_life_base(waypoint: *const Waypoint) bool {
    const type_name = waypoint.type_name orelse return false;
    return std.mem.eql(u8, type_name, "LifeBase");
}

/// Returns the planned stop at an interval's end checkpoint: its `<stopDuration>` if set,
/// else the default at a LifeBase, else none.
fn stop_s_planned(end: *const Waypoint, life_base_stop_s: u32) f64 {
    // An explicit stop only makes sense at a checkpoint, which bounds intervals.
    assert(end.is_section_boundary());
    if (end.stop_s) |stop_s| return @floatFromInt(stop_s);
    if (is_life_base(end)) return @floatFromInt(life_base_stop_s);
    return 0.0;
}

/// A LifeBase is a rest and resupply stop: the runner sheds part of their effort distance.
fn life_base_recover(end: *const Waypoint, progress: *segment.Progress) void {
    if (!is_life_base(end)) return;
    const before = progress.distance_m_effort;
    progress.distance_m_effort *= (1.0 - pace_model.life_base_recovery_ratio);
    assert(progress.distance_m_effort <= before);
}

/// One interval's recalibrated ETA, relative to the runner's current position.
pub const RecalibratedETA = struct {
    /// The interval's position in race order: its section or stage index.
    index: usize,
    index_end: usize,
    /// Moving and stop time still to run within this interval; 0 once it is behind.
    duration_s_remaining: f64,
    /// Time from the runner's position to the end of this interval: the running sum of
    /// `duration_s_remaining`. 0 once it is behind.
    duration_s_remaining_cumulative: f64,
};

pub const Recalibration = struct {
    /// Actual over predicted moving time, gated and clamped; 1 until it can be trusted.
    calibration_factor: f64,
    /// The base pace × the calibration factor: the pace the remaining intervals run at.
    pace_base_s_per_km_calibrated: f64,
    /// The model's moving time for the distance covered, at the original pace.
    duration_s_predicted: f64,
    /// The runner's real elapsed time, as the caller gave it.
    duration_s_actual: f64,
    etas: []RecalibratedETA,

    pub fn deinit(self: *Recalibration, allocator: std.mem.Allocator) void {
        allocator.free(self.etas);
        self.* = undefined;
    }
};

/// Recalibrates the remaining intervals' ETAs from the runner's progress: they are at trace
/// point `index_current` after `elapsed_s_actual` seconds of race. It replays the covered
/// intervals at the original pace to get the model's prediction so far, solves the factor
/// (actual over predicted, gated and clamped), then predicts the rest at the calibrated pace
/// with the circadian clock restarted from the actual elapsed time. Returns null with fewer
/// than two boundaries. The caller owns the result.
pub fn recalibrate(
    allocator: std.mem.Allocator,
    trace: *const Trace,
    waypoints: []const Waypoint,
    kind: BoundaryKind,
    index_current: usize,
    elapsed_s_actual: f64,
    settings: *const pace_model.Settings,
) !?Recalibration {
    settings.assert_valid();
    assert(elapsed_s_actual >= 0 and std.math.isFinite(elapsed_s_actual));
    assert(trace.points.len == 0 or index_current < trace.points.len);
    const boundaries = try boundaries_collect(allocator, waypoints, kind);
    defer allocator.free(boundaries);
    if (boundaries.len < 2) return null;
    const ranges = try ranges_resolve(allocator, trace, boundaries);
    defer allocator.free(ranges);

    var model: segment.Model = .{
        .pace_s_per_km = settings.pace_base_s_per_km,
        .fatigue_coefficient = settings.fatigue_coefficient,
        .clock_start_s = boundaries[0].epoch_s,
    };
    var progress: segment.Progress = .{};
    const replayed = replay(trace, ranges, index_current, model, settings, &progress);

    // Moving time against moving time: the planned stops already behind are part of the
    // actual elapsed time but not of the prediction, so they come off before solving. Rest
    // longer than planned still leaks into the factor; only separate stop tracking could
    // avoid that.
    const elapsed_s_moving = elapsed_s_actual - replayed.stop_s;
    var factor: f64 = 1.0;
    if (elapsed_s_moving > 0 and replayed.moving_s >= prediction_s_min) {
        const ratio = elapsed_s_moving / replayed.moving_s;
        factor = std.math.clamp(ratio, calibration_factor_min, calibration_factor_max);
    }
    assert(factor >= calibration_factor_min and factor <= calibration_factor_max);
    model.pace_s_per_km = settings.pace_base_s_per_km * factor;

    // Restarts the circadian clock from the real elapsed time; fatigue carries over as is.
    progress.elapsed_s = elapsed_s_actual;
    const etas = try allocator.alloc(RecalibratedETA, ranges.len);
    errdefer allocator.free(etas);
    const range_current = replayed.range_current;
    forecast(trace, ranges, index_current, range_current, model, settings, &progress, etas);
    return .{
        .calibration_factor = factor,
        .pace_base_s_per_km_calibrated = model.pace_s_per_km,
        .duration_s_predicted = replayed.moving_s,
        .duration_s_actual = elapsed_s_actual,
        .etas = etas,
    };
}

const Replay = struct {
    /// The model's moving time over the distance covered.
    moving_s: f64,
    /// The planned stops at the checkpoints behind the runner.
    stop_s: f64,
    /// The range the runner is in, or ranges.len once past the last one.
    range_current: usize,
};

/// Runs the model over the covered distance at the original pace: every range behind the
/// runner in full, and the range they are in up to `index_current`.
fn replay(
    trace: *const Trace,
    ranges: []const Range,
    index_current: usize,
    model: segment.Model,
    settings: *const pace_model.Settings,
    progress: *segment.Progress,
) Replay {
    var result: Replay = .{ .moving_s = 0.0, .stop_s = 0.0, .range_current = ranges.len };
    for (ranges, 0..) |*range, range_index| {
        const to = if (index_current >= range.index_end) range.index_end else index_current;
        if (to > range.index_start) {
            const from = range.index_start;
            const step = range_advance(trace, range, from, to, model, settings, progress);
            result.moving_s += step.moving_s;
            result.stop_s += step.stop_s;
        }
        if (index_current < range.index_end) {
            result.range_current = range_index;
            break;
        }
    }
    assert(result.range_current <= ranges.len);
    assert(result.moving_s >= 0 and result.stop_s >= 0);
    return result;
}

/// Fills `etas` with each range's remaining time from `index_current` on; the ranges before
/// `range_current` are behind the runner and get 0.
fn forecast(
    trace: *const Trace,
    ranges: []const Range,
    index_current: usize,
    range_current: usize,
    model: segment.Model,
    settings: *const pace_model.Settings,
    progress: *segment.Progress,
    etas: []RecalibratedETA,
) void {
    assert(etas.len == ranges.len);
    assert(range_current <= ranges.len);
    var cumulative_s: f64 = 0.0;
    for (ranges, etas, 0..) |*range, *eta, range_index| {
        var remaining_s: f64 = 0.0;
        if (range_index >= range_current) {
            const from = if (range_index == range_current)
                @max(index_current, range.index_start)
            else
                range.index_start;
            const to = range.index_end;
            const step = range_advance(trace, range, from, to, model, settings, progress);
            remaining_s = step.moving_s + step.stop_s;
            const cumulative_s_before = cumulative_s;
            cumulative_s += remaining_s;
            assert(cumulative_s >= cumulative_s_before);
        }
        eta.* = .{
            .index = range.boundary,
            .index_end = range.index_end,
            .duration_s_remaining = remaining_s,
            .duration_s_remaining_cumulative = if (remaining_s > 0) cumulative_s else 0.0,
        };
    }
}

const Step = struct { moving_s: f64, stop_s: f64 };

/// Runs the model over `range` from trace point `from` to `to`. When `to` is the range's end
/// the runner reaches the checkpoint: LifeBase recovery applies, and the planned stop is
/// returned.
fn range_advance(
    trace: *const Trace,
    range: *const Range,
    from: usize,
    to: usize,
    model: segment.Model,
    settings: *const pace_model.Settings,
    progress: *segment.Progress,
) Step {
    assert(range.index_start <= from and from <= to and to <= range.index_end);
    const weather = settings.weather.find(range.end.name);
    const metrics = segment.metrics_compute(trace, from, to, model, weather, progress);
    assert(metrics.duration_s >= 0);
    if (to < range.index_end) return .{ .moving_s = metrics.duration_s, .stop_s = 0.0 };
    life_base_recover(&range.end, progress);
    return .{
        .moving_s = metrics.duration_s,
        .stop_s = stop_s_planned(&range.end, settings.life_base_stop_s),
    };
}

/// A flat 30-point route. The caller owns the trace.
fn route_flat(allocator: std.mem.Allocator) !Trace {
    var points: [30][3]f64 = undefined;
    for (&points, 0..) |*point, index| {
        point.* = .{ @as(f64, @floatFromInt(index)) * 0.001, 0.0, 100.0 };
    }
    return Trace.init(allocator, &points);
}

/// Start (point 0), TB1 (5), LB1 (10), LB2 (20), Arrival (29): four sections, or three stages
/// since stages ignore the TimeBarrier.
const route_waypoints = [_]Waypoint{
    waypoint_test(0.000, 0.0, "Start", "Start", null),
    waypoint_test(0.005, 0.0, "TB1", "TimeBarrier", null),
    waypoint_test(0.010, 0.0, "LB1", "LifeBase", null),
    waypoint_test(0.020, 0.0, "LB2", "LifeBase", null),
    waypoint_test(0.029, 0.0, "Arrival", "Arrival", null),
};

/// No planned LifeBase stop, so the tests see moving time only unless they set one.
const settings_no_stop: pace_model.Settings = .{ .life_base_stop_s = 0 };

fn recalibrate_route(
    trace: *const Trace,
    kind: BoundaryKind,
    index_current: usize,
    elapsed_s: f64,
    settings: *const pace_model.Settings,
) !Recalibration {
    const allocator = testing.allocator;
    const waypoints = &route_waypoints;
    const result = try recalibrate(
        allocator,
        trace,
        waypoints,
        kind,
        index_current,
        elapsed_s,
        settings,
    );
    return result.?;
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

test "recalibrate: null with fewer than 2 boundaries" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    const waypoints = route_waypoints[0..1];
    const settings = &settings_no_stop;
    const result = try recalibrate(
        testing.allocator,
        &trace,
        waypoints,
        .section,
        0,
        0.0,
        settings,
    );
    try testing.expectEqual(@as(?Recalibration, null), result);
}

test "recalibrate: no elapsed time keeps the factor at 1, and the cumulative is the sum" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    var result = try recalibrate_route(&trace, .section, 0, 0.0, &settings_no_stop);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1.0), result.calibration_factor);
    const pace_default = pace_model.pace_base_s_per_km_default;
    try testing.expectEqual(pace_default, result.pace_base_s_per_km_calibrated);
    try testing.expectEqual(@as(usize, 4), result.etas.len);
    var sum_s: f64 = 0.0;
    for (result.etas) |eta| {
        try testing.expect(eta.duration_s_remaining > 0.0);
        sum_s += eta.duration_s_remaining;
    }
    try testing.expectApproxEqAbs(sum_s, result.etas[3].duration_s_remaining_cumulative, 1e-6);
}

test "recalibrate: the factor is actual over predicted, clamped" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    // The runner reached LB1 (point 10), slower than predicted.
    var result = try recalibrate_route(&trace, .section, 10, 900.0, &settings_no_stop);
    defer result.deinit(testing.allocator);

    try testing.expect(result.duration_s_predicted >= prediction_s_min);
    const ratio = result.duration_s_actual / result.duration_s_predicted;
    const expected = std.math.clamp(ratio, calibration_factor_min, calibration_factor_max);
    try testing.expectApproxEqAbs(expected, result.calibration_factor, 1e-9);
    try testing.expect(result.calibration_factor > 1.0);
    const pace_expected = pace_model.pace_base_s_per_km_default * result.calibration_factor;
    try testing.expectApproxEqAbs(pace_expected, result.pace_base_s_per_km_calibrated, 1e-9);
}

test "recalibrate: the factor clamps at both bounds" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    var fast = try recalibrate_route(&trace, .section, 10, 1.0, &settings_no_stop);
    defer fast.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, calibration_factor_min), fast.calibration_factor);
    var slow = try recalibrate_route(&trace, .section, 10, 1e7, &settings_no_stop);
    defer slow.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, calibration_factor_max), slow.calibration_factor);
}

test "recalibrate: a slower runner gets longer remaining ETAs" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    var fast = try recalibrate_route(&trace, .section, 10, 300.0, &settings_no_stop);
    defer fast.deinit(testing.allocator);
    var slow = try recalibrate_route(&trace, .section, 10, 1200.0, &settings_no_stop);
    defer slow.deinit(testing.allocator);

    try testing.expect(slow.calibration_factor > fast.calibration_factor);
    const fast_s = fast.etas[fast.etas.len - 1].duration_s_remaining_cumulative;
    const slow_s = slow.etas[slow.etas.len - 1].duration_s_remaining_cumulative;
    try testing.expect(slow_s > fast_s);
}

test "recalibrate: intervals behind the runner are 0, and the cumulative increases" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    // In the middle of section 2 (point 15): sections 0 and 1 are behind.
    var result = try recalibrate_route(&trace, .section, 15, 0.0, &settings_no_stop);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), result.etas.len);
    try testing.expectEqual(@as(f64, 0.0), result.etas[0].duration_s_remaining);
    try testing.expectEqual(@as(f64, 0.0), result.etas[0].duration_s_remaining_cumulative);
    try testing.expectEqual(@as(f64, 0.0), result.etas[1].duration_s_remaining);
    try testing.expect(result.etas[2].duration_s_remaining > 0.0);
    try testing.expect(result.etas[3].duration_s_remaining > 0.0);
    const etas = result.etas;
    const cumulative_2 = etas[2].duration_s_remaining_cumulative;
    try testing.expect(etas[3].duration_s_remaining_cumulative > cumulative_2);
}

test "recalibrate: past the last checkpoint nothing remains" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    var result = try recalibrate_route(&trace, .section, 29, 0.0, &settings_no_stop);
    defer result.deinit(testing.allocator);
    for (result.etas) |eta| try testing.expectEqual(@as(f64, 0.0), eta.duration_s_remaining);
}

test "recalibrate: a partly run interval costs less than running it in full" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    // At LB1 (point 10) section 2 (10 to 20) is all ahead; at point 15 only half of it.
    var at_start = try recalibrate_route(&trace, .section, 10, 0.0, &settings_no_stop);
    defer at_start.deinit(testing.allocator);
    var middle = try recalibrate_route(&trace, .section, 15, 0.0, &settings_no_stop);
    defer middle.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1.0), middle.calibration_factor);
    try testing.expect(middle.etas[2].duration_s_remaining < at_start.etas[2].duration_s_remaining);
    try testing.expect(middle.etas[2].duration_s_remaining > 0.0);
}

test "recalibrate: a planned stop at a passed LifeBase doesn't move the factor" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    // At point 15, LB1 is behind. Adding its stop to both the model and the elapsed time
    // must leave the factor alone: it reflects pace only.
    const stop_s: u32 = 1800;
    const moving_s: f64 = 1500.0;
    var no_stop = try recalibrate_route(&trace, .section, 15, moving_s, &settings_no_stop);
    defer no_stop.deinit(testing.allocator);
    const settings_stop: pace_model.Settings = .{ .life_base_stop_s = stop_s };
    var with_stop = try recalibrate_route(&trace, .section, 15, moving_s + stop_s, &settings_stop);
    defer with_stop.deinit(testing.allocator);

    // The factor engaged, so the equality below means something.
    try testing.expect(no_stop.calibration_factor > 1.0);
    try testing.expect(no_stop.calibration_factor < calibration_factor_max);
    try testing.expectApproxEqAbs(no_stop.calibration_factor, with_stop.calibration_factor, 1e-9);
}

test "recalibrate: stages ignore TimeBarriers" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    var sections = try recalibrate_route(&trace, .section, 0, 0.0, &settings_no_stop);
    defer sections.deinit(testing.allocator);
    var stages = try recalibrate_route(&trace, .stage, 0, 0.0, &settings_no_stop);
    defer stages.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), sections.etas.len);
    try testing.expectEqual(@as(usize, 3), stages.etas.len);
    // Stage 0 (Start to LB1) spans sections 0 (Start to TB1) and 1 (TB1 to LB1).
    const section_0_s = sections.etas[0].duration_s_remaining;
    const sections_s = section_0_s + sections.etas[1].duration_s_remaining;
    try testing.expectApproxEqAbs(sections_s, stages.etas[0].duration_s_remaining, 1e-6);
}

test "recalibrate: stages solve a factor and zero the stages behind" {
    var trace = try route_flat(testing.allocator);
    defer trace.deinit(testing.allocator);
    // The runner reached LB1 (point 10), the end of stage 0, slower than predicted.
    var result = try recalibrate_route(&trace, .stage, 10, 900.0, &settings_no_stop);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.etas.len);
    try testing.expect(result.calibration_factor > 1.0);
    try testing.expectEqual(@as(f64, 0.0), result.etas[0].duration_s_remaining);
    try testing.expect(result.etas[1].duration_s_remaining > 0.0);
    const etas = result.etas;
    const cumulative_1 = etas[1].duration_s_remaining_cumulative;
    try testing.expect(etas[2].duration_s_remaining_cumulative > cumulative_1);
}

test "recalibrate: on a loop, the Arrival resolves to the end of the trace" {
    // Out and back: Start and Arrival share coordinates. Before, recalibration found the
    // Arrival by nearest point, which matched just past the start line.
    var points: [21][3]f64 = undefined;
    for (&points, 0..) |*point, index| {
        const out: f64 = @floatFromInt(if (index <= 10) index else 20 - index);
        point.* = .{ out * 0.001, 0.0, 100.0 };
    }
    var trace = try Trace.init(testing.allocator, &points);
    defer trace.deinit(testing.allocator);
    const waypoints = [_]Waypoint{
        waypoint_test(0.0, 0.0, "Start", "Start", null),
        waypoint_test(0.0, 0.0, "Arrival", "Arrival", null),
    };
    const settings = &settings_no_stop;
    const allocator = testing.allocator;
    var result = (try recalibrate(allocator, &trace, &waypoints, .stage, 0, 0.0, settings)).?;
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.etas.len);
    try testing.expectEqual(@as(usize, 20), result.etas[0].index_end);
}

test "difficulty_from_pace_factor: each threshold" {
    try testing.expectEqual(@as(u8, 1), difficulty_from_pace_factor(1.0));
    try testing.expectEqual(@as(u8, 2), difficulty_from_pace_factor(1.1));
    try testing.expectEqual(@as(u8, 3), difficulty_from_pace_factor(1.4));
    try testing.expectEqual(@as(u8, 4), difficulty_from_pace_factor(1.8));
    try testing.expectEqual(@as(u8, 5), difficulty_from_pace_factor(2.5));
    try testing.expectEqual(@as(u8, 1), difficulty_from_pace_factor(0.7));
}
