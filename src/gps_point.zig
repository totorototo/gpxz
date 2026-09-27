//! A GPS point is `[3]f64`: latitude and longitude in degrees, then elevation in meters.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const math = std.math;

pub const latitude_index = 0;
pub const longitude_index = 1;
pub const elevation_index = 2;

/// The mean Earth radius, which Haversine treats as a sphere.
const earth_radius_m = 6_371_000.0;

/// Returns the great-circle (Haversine) distance in meters between two points, ignoring
/// elevation.
pub fn distance(a: [3]f64, b: [3]f64) f64 {
    assert(coordinates_valid(a));
    assert(coordinates_valid(b));
    const latitude_a = math.degreesToRadians(a[latitude_index]);
    const latitude_b = math.degreesToRadians(b[latitude_index]);
    const latitude_delta = latitude_b - latitude_a;
    const longitude_delta = math.degreesToRadians(b[longitude_index]) -
        math.degreesToRadians(a[longitude_index]);

    const latitude_half_sin = math.sin(latitude_delta / 2.0);
    const longitude_half_sin = math.sin(longitude_delta / 2.0);
    const h = latitude_half_sin * latitude_half_sin +
        math.cos(latitude_a) * math.cos(latitude_b) * longitude_half_sin * longitude_half_sin;
    // Rounding can push h a hair past 1 for antipodal points; atan2 needs 1 - h >= 0.
    const h_clamped = math.clamp(h, 0.0, 1.0);
    const distance_m = earth_radius_m * 2.0 * math.atan2(@sqrt(h_clamped), @sqrt(1.0 - h_clamped));
    assert(distance_m >= 0);
    assert(distance_m <= math.pi * earth_radius_m + 1.0);
    return distance_m;
}

/// Returns the initial bearing from `a` to `b` in degrees, in [0, 360): 0 is north, 90 east.
pub fn bearing_to(a: [3]f64, b: [3]f64) f64 {
    assert(coordinates_valid(a));
    assert(coordinates_valid(b));
    const latitude_a = math.degreesToRadians(a[latitude_index]);
    const latitude_b = math.degreesToRadians(b[latitude_index]);
    const longitude_delta = math.degreesToRadians(b[longitude_index]) -
        math.degreesToRadians(a[longitude_index]);
    const y = math.sin(longitude_delta) * math.cos(latitude_b);
    const x = math.cos(latitude_a) * math.sin(latitude_b) -
        math.sin(latitude_a) * math.cos(latitude_b) * math.cos(longitude_delta);

    var bearing = math.radiansToDegrees(math.atan2(y, x));
    if (bearing < 0.0) bearing += 360.0;
    // atan2 returns -0.0 for due north, and -0.0 + 360 would round to 360.
    if (bearing >= 360.0) bearing -= 360.0;
    assert(bearing >= 0.0 and bearing < 360.0);
    return bearing;
}

/// The parser rejects coordinates out of range, so a point that reaches the math is valid.
fn coordinates_valid(point: [3]f64) bool {
    const latitude = point[latitude_index];
    const longitude = point[longitude_index];
    return latitude >= -90.0 and latitude <= 90.0 and longitude >= -180.0 and longitude <= 180.0;
}

test "distance: the same point is 0 m away" {
    const point = [3]f64{ 45.0, 6.0, 1000.0 };
    try testing.expectEqual(@as(f64, 0), distance(point, point));
}

test "distance: one degree on the equator is about 111.2 km either way" {
    const origin = [3]f64{ 0.0, 0.0, 0.0 };
    try testing.expectApproxEqAbs(111_195.0, distance(origin, .{ 0.0, 1.0, 0.0 }), 1.0);
    try testing.expectApproxEqAbs(111_195.0, distance(origin, .{ 1.0, 0.0, 0.0 }), 1.0);
}

test "distance: symmetric and ignores elevation" {
    const paris = [3]f64{ 48.8566, 2.3522, 0.0 };
    const london = [3]f64{ 51.5074, -0.1276, 5000.0 };
    try testing.expectEqual(distance(paris, london), distance(london, paris));
    // The great-circle distance from Paris to London is about 343.6 km.
    try testing.expectApproxEqAbs(343_560.0, distance(paris, london), 1000.0);
}

test "distance: antipodal points are half the circumference apart" {
    const north = [3]f64{ 90.0, 0.0, 0.0 };
    const south = [3]f64{ -90.0, 0.0, 0.0 };
    try testing.expectApproxEqAbs(math.pi * earth_radius_m, distance(north, south), 1e-6);
    const east = [3]f64{ 0.0, 180.0, 0.0 };
    const west = [3]f64{ 0.0, -180.0, 0.0 };
    try testing.expectApproxEqAbs(0.0, distance(east, west), 1e-6);
}

test "bearing_to: the four cardinal directions" {
    const origin = [3]f64{ 45.0, 0.0, 0.0 };
    try testing.expectApproxEqAbs(0.0, bearing_to(origin, .{ 46.0, 0.0, 0.0 }), 0.1);
    try testing.expectApproxEqAbs(90.0, bearing_to(origin, .{ 45.0, 1.0, 0.0 }), 1.0);
    try testing.expectApproxEqAbs(180.0, bearing_to(origin, .{ 44.0, 0.0, 0.0 }), 0.1);
    try testing.expectApproxEqAbs(270.0, bearing_to(origin, .{ 45.0, -1.0, 0.0 }), 1.0);
}

test "bearing_to: stays below 360" {
    const origin = [3]f64{ 45.0, 0.0, 0.0 };
    // Due north, and the same point, where atan2 may return -0.0.
    try testing.expect(bearing_to(origin, .{ 46.0, 0.0, 0.0 }) < 360.0);
    try testing.expect(bearing_to(origin, origin) < 360.0);
    // Just west of north.
    try testing.expect(bearing_to(origin, .{ 46.0, -1e-12, 0.0 }) < 360.0);
}

test "coordinates_valid: the bounds are inclusive" {
    try testing.expect(coordinates_valid(.{ 90.0, 180.0, 0.0 }));
    try testing.expect(coordinates_valid(.{ -90.0, -180.0, 0.0 }));
    try testing.expect(!coordinates_valid(.{ 90.001, 0.0, 0.0 }));
    try testing.expect(!coordinates_valid(.{ 0.0, -180.001, 0.0 }));
    try testing.expect(!coordinates_valid(.{ math.nan(f64), 0.0, 0.0 }));
}
