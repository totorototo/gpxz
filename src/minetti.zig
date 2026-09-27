//! The metabolic cost of running on a slope, from Minetti et al. (2002), J. Exp. Biol.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// The model was fitted on slopes from -45% to +45% and isn't reliable beyond them.
pub const slope_min = -0.45;
pub const slope_max = 0.45;

/// The cost at zero slope, in J·kg⁻¹·m⁻¹: the denominator of `pace_factor`.
pub const metabolic_cost_flat = 3.6;

/// Returns the energy cost of running in J·kg⁻¹·m⁻¹ on `slope` (rise over run, a
/// fraction, not a percentage). Slopes outside the model's domain are clamped to it.
///
///   slope =  0.00 → 3.6  (flat)
///   slope = -0.10 → ~2.8 (gentle descent, the cheapest terrain)
///   slope = +0.10 → ~6.0 (moderate climb, ×1.67 flat)
///   slope = +0.20 → ~9.8 (steep climb, ×2.72 flat)
pub fn metabolic_cost(slope: f64) f64 {
    assert(!std.math.isNan(slope));
    const x = std.math.clamp(slope, slope_min, slope_max);
    const x_squared = x * x;
    const x_cubed = x_squared * x;
    const x_fourth = x_cubed * x;
    const x_fifth = x_fourth * x;
    const cost = 155.4 * x_fifth - 30.4 * x_fourth - 43.3 * x_cubed + 46.3 * x_squared +
        19.5 * x + 3.6;
    // The polynomial stays positive over the whole domain: its minimum is near -0.2.
    assert(cost > 0);
    return cost;
}

/// Returns the pace factor on `slope` relative to flat terrain, Cmet(slope) / Cmet(0).
/// Multiply a flat pace by it to get the pace of the same effort on this slope.
///
///   slope =  0.00 → 1.00  (flat)
///   slope = +0.10 → ~1.67 (a 5:00/km effort runs at 8:21/km)
///   slope = -0.10 → ~0.78 (a gentle descent is cheaper than flat)
pub fn pace_factor(slope: f64) f64 {
    const factor = metabolic_cost(slope) / metabolic_cost_flat;
    assert(factor > 0);
    assert(std.math.isFinite(factor));
    return factor;
}

test "metabolic_cost: flat terrain costs 3.6" {
    try testing.expectApproxEqAbs(metabolic_cost_flat, metabolic_cost(0.0), 1e-9);
}

test "metabolic_cost: a gentle descent costs less than flat" {
    try testing.expect(metabolic_cost(-0.10) < metabolic_cost_flat);
}

test "metabolic_cost: climbs cost progressively more" {
    try testing.expect(metabolic_cost(0.10) > metabolic_cost(0.05));
    try testing.expect(metabolic_cost(0.20) > metabolic_cost(0.10));
    try testing.expect(metabolic_cost(0.30) > metabolic_cost(0.20));
}

test "metabolic_cost: a steep descent costs more than a gentle one" {
    // Below about -15% eccentric braking makes the cost rise again.
    try testing.expect(metabolic_cost(-0.40) > metabolic_cost(-0.15));
}

test "metabolic_cost: clamps at the domain bounds" {
    try testing.expectEqual(metabolic_cost(slope_min), metabolic_cost(-0.99));
    try testing.expectEqual(metabolic_cost(slope_max), metabolic_cost(0.99));
    const infinity = std.math.inf(f64);
    try testing.expectEqual(metabolic_cost(slope_min), metabolic_cost(-infinity));
    try testing.expectEqual(metabolic_cost(slope_max), metabolic_cost(infinity));
}

test "metabolic_cost: positive across the whole domain" {
    var slope: f64 = slope_min;
    while (slope <= slope_max) : (slope += 0.01) try testing.expect(metabolic_cost(slope) > 0);
}

test "pace_factor: flat is 1" {
    try testing.expectApproxEqAbs(1.0, pace_factor(0.0), 1e-9);
}

test "pace_factor: +10% is about 1.67, Minetti's table value" {
    try testing.expectApproxEqAbs(1.67, pace_factor(0.10), 0.05);
}

test "pace_factor: a gentle descent is below 1" {
    try testing.expect(pace_factor(-0.10) < 1.0);
}
