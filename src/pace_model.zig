//! The pace model: a flat-terrain base pace multiplied by slope (Minetti), fatigue, circadian
//! and weather factors. Every factor is at least 1 except slope, which drops below 1 on a
//! gentle descent.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const minetti = @import("minetti.zig");

/// The default flat-terrain pace: 500 s/km is 8:20/km, the "Moderate" preset in terminus.
pub const pace_base_s_per_km_default = 500.0;

/// The default fatigue coefficient, the "Moderate" preset. On a 224 km, 8000 m D+ course the
/// effort distance is about 234 km, so fatigue at the finish is exp(0.002 × 234) ≈ 1.60.
/// Presets: Low 0.001, Moderate 0.002, High 0.003, Very high 0.004.
pub const fatigue_coefficient_default = 0.002;

/// The share of accumulated effort distance a runner sheds at a LifeBase: mandatory rest and
/// resupply at major checkpoints.
pub const life_base_recovery_ratio = 0.20;

/// The default stop at a LifeBase, used when the GPX has no `<stop_s>` and the caller
/// sets none.
pub const life_base_stop_s_default: u32 = 3600;

/// The runner's inputs to the pace model. The defaults are the "Moderate" presets.
pub const Settings = struct {
    /// The flat-terrain pace.
    pace_base_s_per_km: f64 = pace_base_s_per_km_default,
    fatigue_coefficient: f64 = fatigue_coefficient_default,
    /// The planned stop at a LifeBase whose waypoint sets no `<stopDuration>`.
    life_base_stop_s: u32 = life_base_stop_s_default,
    weather: WeatherLookup = .empty,

    pub fn assert_valid(settings: *const Settings) void {
        assert(settings.pace_base_s_per_km > 0 and std.math.isFinite(settings.pace_base_s_per_km));
        assert(settings.fatigue_coefficient >= 0);
        assert(std.math.isFinite(settings.fatigue_coefficient));
        assert(settings.weather.names.len == settings.weather.values.len);
    }
};

/// Returns the fatigue multiplier (at least 1) after `distance_km_effort` of effort-weighted
/// distance. It is exponential rather than linear (1 + k·d) because late-race slowdown
/// accelerates rather than growing at a constant rate.
pub fn fatigue_factor(distance_km_effort: f64, coefficient: f64) f64 {
    assert(distance_km_effort >= 0);
    assert(coefficient >= 0);
    const factor = @exp(coefficient * distance_km_effort);
    assert(factor >= 1.0);
    return factor;
}

/// The circadian low: a half-cosine bump centered at 3:30 UTC, 2 hours wide on each side,
/// peaking at a 15% slowdown. GPX timestamps are UTC, so a runner at UTC+2 meets the peak
/// around 5:30 local time.
const circadian_center_h = 3.5;
const circadian_half_width_h = 2.0;
const circadian_penalty_max = 0.15;

/// Returns the circadian slowdown (from 1 to 1.15) at Unix time `epoch_s`.
pub fn circadian_factor(epoch_s: i64) f64 {
    const hours_utc = @mod(@as(f64, @floatFromInt(epoch_s)) / 3600.0, 24.0);
    assert(hours_utc >= 0 and hours_utc < 24.0);
    const offset_h = hours_utc - circadian_center_h;
    if (@abs(offset_h) >= circadian_half_width_h) return 1.0;

    const position = offset_h / circadian_half_width_h;
    // 1 at the center, 0 at the edges.
    const bump = 0.5 * (1.0 + @cos(std.math.pi * position));
    const factor = 1.0 + circadian_penalty_max * bump;
    assert(factor >= 1.0 and factor <= 1.0 + circadian_penalty_max);
    return factor;
}

/// One point's pace factors. `terrain` is the slope term alone, which drives effort-weighted
/// distance; `combined` also folds in fatigue, circadian and weather, and drives time.
pub const PaceFactors = struct {
    terrain: f64,
    combined: f64,
};

/// Returns one point's pace factors: the single place the slope term joins the others.
/// `slope` is rise over run. `clock_start_s` is the race start epoch, or null for a neutral
/// circadian factor; `elapsed_s` is added to it. `weather` is `weather_factor()` for the
/// segment, computed once by the caller since weather is constant across a segment.
pub fn factors_compute(
    slope: f64,
    distance_km_effort: f64,
    fatigue_coefficient: f64,
    clock_start_s: ?i64,
    elapsed_s: f64,
    weather: f64,
) PaceFactors {
    assert(elapsed_s >= 0 and std.math.isFinite(elapsed_s));
    assert(weather >= 1.0);
    const terrain = minetti.pace_factor(slope);
    const fatigue = fatigue_factor(distance_km_effort, fatigue_coefficient);
    const circadian = if (clock_start_s) |start_s|
        circadian_factor(start_s + @as(i64, @intFromFloat(elapsed_s)))
    else
        1.0;
    const factors: PaceFactors = .{
        .terrain = terrain,
        .combined = terrain * fatigue * circadian * weather,
    };
    assert(factors.combined >= factors.terrain);
    return factors;
}

// Weather is one more multiplicative penalty. Every weather factor is at least 1: bad weather
// only slows a runner, and neutral weather (cool, dry, calm) is exactly 1. The inputs match
// the Open-Meteo fields terminus fetches.

/// Forecast conditions at a point and time along the route. A flat struct of f64, so Zigar
/// can marshal it from JavaScript.
pub const WeatherConditions = struct {
    /// Air temperature (Open-Meteo `temperature_2m`).
    temperature_c: f64,
    /// Relative humidity, 0 to 100: it amplifies heat stress.
    humidity_percent: f64,
    /// Wind speed (`windspeed_10m`).
    wind_kmh: f64,
    /// Precipitation probability, 0 to 100 (`precipitation_probability`).
    precipitation_probability_percent: f64,
};

/// The best ambient temperature for endurance running: no penalty here.
pub const temperature_c_optimal = 12.0;
/// The penalty per °C of apparent temperature above the optimum: 0.006 is about +3% per 5 °C,
/// in line with studies of marathon times against WBGT.
pub const heat_penalty_per_c = 0.006;
/// Below this, cold adds a small penalty (stiffness, footing, clothing).
pub const cold_threshold_c = 0.0;
pub const cold_penalty_per_c = 0.003;
/// Below this, wind has a negligible effect.
pub const wind_threshold_kmh = 15.0;
pub const wind_penalty_per_kmh = 0.004;
pub const wind_penalty_max = 0.20;
/// The penalty at a 100% precipitation probability: a wet, muddy, low-traction trail.
pub const precipitation_penalty_max = 0.08;

/// Cool, dry and calm: `weather_factor(weather_neutral)` is exactly 1. Use it when there is
/// no forecast, so estimates don't change.
pub const weather_neutral: WeatherConditions = .{
    .temperature_c = temperature_c_optimal,
    .humidity_percent = 50.0,
    .wind_kmh = 0.0,
    .precipitation_probability_percent = 0.0,
};

/// Returns the feels-like temperature. Humidity only matters when it's warm: above 20 °C
/// sweat evaporates less readily, so high humidity adds to the heat load.
pub fn temperature_c_apparent(temperature_c: f64, humidity_percent: f64) f64 {
    assert(!std.math.isNan(temperature_c));
    if (temperature_c <= 20.0) return temperature_c;
    const humidity = std.math.clamp(humidity_percent, 0.0, 100.0);
    // In units of 10% humidity above 40%.
    const humidity_excess = @max(0.0, humidity - 40.0) / 10.0;
    const apparent = temperature_c + humidity_excess * (temperature_c - 20.0) * 0.1;
    assert(apparent >= temperature_c);
    return apparent;
}

/// Returns the thermal factor: a heat penalty when the apparent temperature is above the
/// optimum, a cold penalty when the air is below the cold threshold, 1 in between.
pub fn thermal_factor(temperature_c: f64, humidity_percent: f64) f64 {
    const apparent_c = temperature_c_apparent(temperature_c, humidity_percent);
    if (apparent_c > temperature_c_optimal) {
        return 1.0 + (apparent_c - temperature_c_optimal) * heat_penalty_per_c;
    }
    if (temperature_c < cold_threshold_c) {
        return 1.0 + (cold_threshold_c - temperature_c) * cold_penalty_per_c;
    }
    return 1.0;
}

/// Returns the wind factor. A forecast gives a speed with no bearing relative to the runner,
/// so this models the average exposure over a loop or out-and-back, not a pure headwind.
pub fn wind_factor(wind_kmh: f64) f64 {
    assert(!std.math.isNan(wind_kmh));
    if (wind_kmh <= wind_threshold_kmh) return 1.0;
    const penalty = (wind_kmh - wind_threshold_kmh) * wind_penalty_per_kmh;
    return 1.0 + @min(wind_penalty_max, penalty);
}

/// Returns the precipitation factor. The probability stands in for the chance of wet,
/// muddy, low-traction ground.
pub fn precipitation_factor(probability_percent: f64) f64 {
    assert(!std.math.isNan(probability_percent));
    const probability = std.math.clamp(probability_percent, 0.0, 100.0) / 100.0;
    return 1.0 + precipitation_penalty_max * probability;
}

/// Returns the weather factor, thermal × wind × precipitation.
pub fn weather_factor(conditions: WeatherConditions) f64 {
    const factor = thermal_factor(conditions.temperature_c, conditions.humidity_percent) *
        wind_factor(conditions.wind_kmh) *
        precipitation_factor(conditions.precipitation_probability_percent);
    assert(factor >= 1.0);
    return factor;
}

/// Forecasts keyed by checkpoint name. The weather a runner meets depends on their ETA,
/// which is itself an output of the pace model. A stable key breaks that cycle: the caller
/// computes ETAs with neutral weather, fetches a forecast per checkpoint, then computes again
/// with this lookup filled. Unknown names are neutral, so partial coverage only adjusts the
/// sections that have a forecast.
pub const WeatherLookup = struct {
    /// `names[i]` has the conditions `values[i]`: the two have the same length.
    names: []const []const u8,
    values: []const WeatherConditions,

    pub const empty: WeatherLookup = .{ .names = &.{}, .values = &.{} };

    /// Returns the conditions for `name`, or neutral ones when it has none.
    pub fn find(self: WeatherLookup, name: []const u8) WeatherConditions {
        assert(self.names.len == self.values.len);
        for (self.names, self.values) |candidate, conditions| {
            if (std.mem.eql(u8, candidate, name)) return conditions;
        }
        return weather_neutral;
    }

    pub fn factor_for(self: WeatherLookup, name: []const u8) f64 {
        return weather_factor(self.find(name));
    }
};

test "fatigue_factor: no effort is 1" {
    try testing.expectEqual(@as(f64, 1.0), fatigue_factor(0.0, fatigue_coefficient_default));
    try testing.expectEqual(@as(f64, 1.0), fatigue_factor(100.0, 0.0));
}

test "fatigue_factor: grows faster than the linear model" {
    const distance_km: f64 = 100.0;
    const linear = 1.0 + fatigue_coefficient_default * distance_km;
    try testing.expect(fatigue_factor(distance_km, fatigue_coefficient_default) > linear);
}

test "fatigue_factor: about 1.60 at a 234 km effort distance" {
    try testing.expectApproxEqAbs(1.60, fatigue_factor(234.0, fatigue_coefficient_default), 0.01);
}

test "life_base_recovery_ratio: between 0 and 1" {
    try testing.expect(life_base_recovery_ratio > 0.0);
    try testing.expect(life_base_recovery_ratio < 1.0);
}

test "circadian_factor: 1 at noon, the peak at 3:30" {
    try testing.expectEqual(@as(f64, 1.0), circadian_factor(12 * 3600));
    const peak = circadian_factor(3 * 3600 + 30 * 60);
    try testing.expectApproxEqAbs(1.0 + circadian_penalty_max, peak, 1e-9);
}

test "circadian_factor: 1 at the window's edges" {
    try testing.expectEqual(@as(f64, 1.0), circadian_factor(1 * 3600 + 30 * 60));
    try testing.expectEqual(@as(f64, 1.0), circadian_factor(5 * 3600 + 30 * 60));
    // Just inside: barely above 1.
    const inside = circadian_factor(1 * 3600 + 31 * 60);
    try testing.expect(inside > 1.0 and inside < 1.001);
}

test "circadian_factor: at least 1 over a whole day" {
    var epoch_s: i64 = 0;
    while (epoch_s < 24 * 3600) : (epoch_s += 600) {
        try testing.expect(circadian_factor(epoch_s) >= 1.0);
    }
}

test "circadian_factor: repeats every day, and before 1970" {
    const day_0 = circadian_factor(3 * 3600 + 30 * 60);
    try testing.expectEqual(day_0, circadian_factor(2 * 24 * 3600 + 3 * 3600 + 30 * 60));
    try testing.expectEqual(day_0, circadian_factor(-24 * 3600 + 3 * 3600 + 30 * 60));
}

test "factors_compute: flat, fresh, no clock and neutral weather is neutral" {
    const factors = factors_compute(0.0, 0.0, fatigue_coefficient_default, null, 0.0, 1.0);
    try testing.expectApproxEqAbs(1.0, factors.terrain, 1e-9);
    try testing.expectApproxEqAbs(1.0, factors.combined, 1e-9);
}

test "factors_compute: terrain is the Minetti factor for the slope" {
    const factors = factors_compute(0.10, 0.0, fatigue_coefficient_default, null, 0.0, 1.0);
    try testing.expectEqual(minetti.pace_factor(0.10), factors.terrain);
}

test "factors_compute: combined is the product of every factor" {
    const clock_start_s: i64 = 1_700_000_000;
    const coefficient = fatigue_coefficient_default;
    const factors = factors_compute(0.08, 50.0, coefficient, clock_start_s, 3600.0, 1.05);
    const expected = minetti.pace_factor(0.08) * fatigue_factor(50.0, coefficient) *
        circadian_factor(clock_start_s + 3600) * 1.05;
    try testing.expectApproxEqAbs(expected, factors.combined, 1e-12);
}

test "factors_compute: no clock leaves circadian neutral" {
    const coefficient = fatigue_coefficient_default;
    const without_clock = factors_compute(0.0, 0.0, coefficient, null, 0.0, 1.0);
    // Noon UTC is neutral too, so the two agree...
    const noon = factors_compute(0.0, 0.0, coefficient, 12 * 3600, 0.0, 1.0);
    try testing.expectEqual(without_clock.combined, noon.combined);
    // ...but at the circadian peak they differ.
    const peak = factors_compute(0.0, 0.0, coefficient, 3 * 3600 + 30 * 60, 0.0, 1.0);
    try testing.expect(peak.combined > without_clock.combined);
}

test "temperature_c_apparent: humidity has no effect when it's cool" {
    try testing.expectEqual(@as(f64, 10.0), temperature_c_apparent(10.0, 90.0));
    try testing.expectEqual(@as(f64, 20.0), temperature_c_apparent(20.0, 100.0));
}

test "temperature_c_apparent: humidity above 40% inflates warm temperatures" {
    try testing.expect(temperature_c_apparent(30.0, 90.0) > 30.0);
    try testing.expectEqual(@as(f64, 30.0), temperature_c_apparent(30.0, 40.0));
    // Humidity out of range is clamped to 100%.
    const saturated_c = temperature_c_apparent(30.0, 100.0);
    try testing.expectEqual(saturated_c, temperature_c_apparent(30.0, 150.0));
}

test "thermal_factor: neutral at the optimum and between cold and optimum" {
    try testing.expectEqual(@as(f64, 1.0), thermal_factor(temperature_c_optimal, 50.0));
    try testing.expectEqual(@as(f64, 1.0), thermal_factor(5.0, 50.0));
    try testing.expectEqual(@as(f64, 1.0), thermal_factor(cold_threshold_c, 50.0));
}

test "thermal_factor: heat slows, and humidity makes it worse" {
    const dry = thermal_factor(30.0, 40.0);
    const humid = thermal_factor(30.0, 90.0);
    try testing.expect(dry > 1.0);
    try testing.expect(humid > dry);
}

test "thermal_factor: cold adds a small penalty" {
    // -10 °C: 1 + 10 × 0.003.
    try testing.expectApproxEqAbs(1.03, thermal_factor(-10.0, 50.0), 1e-9);
}

test "wind_factor: calm up to the threshold, then a penalty, then the cap" {
    try testing.expectEqual(@as(f64, 1.0), wind_factor(0.0));
    try testing.expectEqual(@as(f64, 1.0), wind_factor(wind_threshold_kmh));
    // 40 km/h: 1 + (40 - 15) × 0.004.
    try testing.expectApproxEqAbs(1.10, wind_factor(40.0), 1e-9);
    try testing.expectEqual(1.0 + wind_penalty_max, wind_factor(1000.0));
}

test "precipitation_factor: from neutral when dry to the maximum when certain, clamped" {
    try testing.expectEqual(@as(f64, 1.0), precipitation_factor(0.0));
    try testing.expectEqual(1.0 + precipitation_penalty_max, precipitation_factor(100.0));
    try testing.expectEqual(@as(f64, 1.0), precipitation_factor(-20.0));
    try testing.expectEqual(1.0 + precipitation_penalty_max, precipitation_factor(150.0));
}

test "weather_factor: neutral is exactly 1" {
    try testing.expectEqual(@as(f64, 1.0), weather_factor(weather_neutral));
}

test "weather_factor: the product of the three factors" {
    const conditions: WeatherConditions = .{
        .temperature_c = 30.0,
        .humidity_percent = 90.0,
        .wind_kmh = 40.0,
        .precipitation_probability_percent = 100.0,
    };
    const expected = thermal_factor(30.0, 90.0) * wind_factor(40.0) * precipitation_factor(100.0);
    try testing.expectEqual(expected, weather_factor(conditions));
}

test "weather_factor: at least 1 across a broad sweep" {
    const temperatures_c = [_]f64{ -20, -5, 0, 12, 20, 25, 35, 45 };
    const humidities = [_]f64{ 0, 40, 75, 100 };
    const winds_kmh = [_]f64{ 0, 15, 30, 60, 200 };
    const probabilities = [_]f64{ 0, 50, 100 };
    for (temperatures_c) |temperature_c| for (humidities) |humidity| for (winds_kmh) |wind| {
        for (probabilities) |probability| {
            const factor = weather_factor(.{
                .temperature_c = temperature_c,
                .humidity_percent = humidity,
                .wind_kmh = wind,
                .precipitation_probability_percent = probability,
            });
            try testing.expect(factor >= 1.0);
        }
    };
}

test "WeatherLookup: empty is neutral for every name" {
    try testing.expectEqual(@as(f64, 1.0), WeatherLookup.empty.factor_for("anything"));
    try testing.expectEqual(weather_neutral, WeatherLookup.empty.find(""));
}

test "WeatherLookup: finds conditions by name, and unknown names are neutral" {
    const hot: WeatherConditions = .{
        .temperature_c = 30.0,
        .humidity_percent = 90.0,
        .wind_kmh = 40.0,
        .precipitation_probability_percent = 100.0,
    };
    const names = [_][]const u8{ "Courmayeur", "Champex" };
    const values = [_]WeatherConditions{ hot, weather_neutral };
    const lookup: WeatherLookup = .{ .names = &names, .values = &values };

    try testing.expectEqual(hot, lookup.find("Courmayeur"));
    try testing.expect(lookup.factor_for("Courmayeur") > 1.0);
    try testing.expectEqual(@as(f64, 1.0), lookup.factor_for("Champex"));
    try testing.expectEqual(@as(f64, 1.0), lookup.factor_for("Unknown"));
    // Names match exactly: case and prefixes count.
    try testing.expectEqual(@as(f64, 1.0), lookup.factor_for("courmayeur"));
    try testing.expectEqual(@as(f64, 1.0), lookup.factor_for("Courma"));
}
