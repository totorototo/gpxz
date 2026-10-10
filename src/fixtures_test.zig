//! Tests against real GPX files in testdata/, written by tools other than gpxz. Unlike the
//! hand-built strings in gpx.zig, these check gpxz against routes it didn't make. The expected
//! values come from outside gpxz: the file's own text (counted with grep, times converted with
//! Python) and the distance trail-passion.net printed in each file's metadata link. See
//! testdata/README.md for where each file comes from.
//!
//! The files are embedded at compile time (build.zig names each one), so the tests do no I/O
//! and don't depend on the working directory.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const gpxz = @import("gpxz");

/// What a fixture must parse to. Every value is read from the file by something other than
/// gpxz.
const Expected = struct {
    name: []const u8,
    /// `<trkpt` occurrences.
    points: u32,
    /// Typed waypoints in file order are Start, then TimeBarriers and LifeBases, then Arrival.
    time_barriers: u32,
    life_bases: u32,
    /// The Start and Arrival `<time>`, as Unix epoch seconds.
    start_s: i64,
    arrival_s: i64,
    /// The distance in the metadata link text, computed by trail-passion.net.
    distance_km_reference: f64,
    /// The `<ele>` of the first and last track points.
    elevation_first_m: f64,
    elevation_last_m: f64,
};

/// trail-passion.net measures the same points with its own formula and precision, so the two
/// totals differ slightly; the largest gap across the fixtures is 0.8%.
const distance_tolerance_ratio = 0.01;

/// D+ minus D- telescopes to the net climb, but denoising drops a few meters at the ends of
/// the route; the largest gap across the fixtures is 2 m.
const elevation_net_tolerance_m = 5.0;

fn fixture_check(bytes: []const u8, expected: *const Expected) !void {
    assert(bytes.len > 0);
    assert(expected.points > 0);

    var data = try gpxz.parse(testing.allocator, bytes, &.{});
    defer data.deinit(testing.allocator);

    try testing.expectEqualStrings(expected.name, data.metadata.name.?);
    assert(data.points_full_resolution.len % 3 == 0);
    try testing.expectEqual(@as(usize, expected.points), data.points_full_resolution.len / 3);

    try waypoints_check(data.waypoints, expected);
    // Every waypoint is typed, so each one bounds a section; LifeBases also bound stages.
    try testing.expectEqual(data.waypoints.len - 1, data.sections.?.len);
    try testing.expectEqual(@as(usize, expected.life_bases + 1), data.stages.?.len);
    // The plan has a line per checkpoint, the Start included, and ends at the Arrival.
    const plan = data.plan.?;
    try testing.expectEqual(data.waypoints.len, plan.len);
    try testing.expectEqualStrings("Arrival", plan[plan.len - 1].type_name.?);

    const trace = &data.trace;
    const distance_km = trace.distance_m / 1000.0;
    const distance_error_ratio =
        @abs(distance_km - expected.distance_km_reference) / expected.distance_km_reference;
    try testing.expect(distance_error_ratio <= distance_tolerance_ratio);

    const elevation_net_m = trace.elevation_gain_m - trace.elevation_loss_m;
    const elevation_net_expected_m = expected.elevation_last_m - expected.elevation_first_m;
    try testing.expect(@abs(elevation_net_m - elevation_net_expected_m) <=
        elevation_net_tolerance_m);
}

fn waypoints_check(waypoints: []const gpxz.Waypoint, expected: *const Expected) !void {
    // Start and Arrival bracket the others.
    try testing.expectEqual(
        @as(usize, expected.time_barriers + expected.life_bases + 2),
        waypoints.len,
    );
    try testing.expectEqualStrings("Start", waypoints[0].type_name.?);
    try testing.expectEqualStrings("Arrival", waypoints[waypoints.len - 1].type_name.?);
    try testing.expectEqual(expected.start_s, waypoints[0].epoch_s.?);
    try testing.expectEqual(expected.arrival_s, waypoints[waypoints.len - 1].epoch_s.?);

    var time_barriers: u32 = 0;
    var life_bases: u32 = 0;
    for (waypoints[1 .. waypoints.len - 1]) |waypoint| {
        const kind = waypoint.type_name.?;
        if (std.mem.eql(u8, kind, "TimeBarrier")) {
            time_barriers += 1;
        } else if (std.mem.eql(u8, kind, "LifeBase")) {
            life_bases += 1;
        } else {
            return error.TestUnexpectedWaypointType;
        }
    }
    try testing.expectEqual(expected.time_barriers, time_barriers);
    try testing.expectEqual(expected.life_bases, life_bases);
}

test "grp-40-gela-2026.gpx: a loop from Piau" {
    try fixture_check(@embedFile("grp-40-gela-2026.gpx"), &.{
        .name = "GRP 2026 Tour de la Gela",
        .points = 1861,
        .time_barriers = 3,
        .life_bases = 0,
        .start_s = 1787293800,
        .arrival_s = 1787338800,
        .distance_km_reference = 41.6,
        .elevation_first_m = 1863,
        .elevation_last_m = 1863,
    });
}

test "grp-40-neouvielle-2026.gpx: the fewest waypoints" {
    try fixture_check(@embedFile("grp-40-neouvielle-2026.gpx"), &.{
        .name = "GRP 2026 Tour du Néouvielle",
        .points = 2016,
        .time_barriers = 2,
        .life_bases = 0,
        .start_s = 1787292000,
        .arrival_s = 1787335200,
        .distance_km_reference = 43.1,
        .elevation_first_m = 800,
        .elevation_last_m = 791,
    });
}

test "grp-50-2026.gpx: point to point, 860 m net descent" {
    try fixture_check(@embedFile("grp-50-2026.gpx"), &.{
        .name = "GRP 2026 Tour du Bastan",
        .points = 7141,
        .time_barriers = 3,
        .life_bases = 0,
        .start_s = 1787288400,
        .arrival_s = 1787344200,
        .distance_km_reference = 53.3,
        .elevation_first_m = 1653,
        .elevation_last_m = 792,
    });
}

test "grp-60-2026.gpx: point to point, 1070 m net descent" {
    try fixture_check(@embedFile("grp-60-2026.gpx"), &.{
        .name = "GRP 2026 Tour du Moudang",
        .points = 3117,
        .time_barriers = 4,
        .life_bases = 0,
        .start_s = 1787283000,
        .arrival_s = 1787344200,
        .distance_km_reference = 60.8,
        .elevation_first_m = 1864,
        .elevation_last_m = 791,
    });
}

test "grp-80-2026.gpx: overnight, arrival on the next day" {
    try fixture_check(@embedFile("grp-80-2026.gpx"), &.{
        .name = "GRP 2026 Tour des Lacs",
        .points = 4200,
        .time_barriers = 7,
        .life_bases = 0,
        .start_s = 1787281200,
        .arrival_s = 1787371200,
        .distance_km_reference = 80.5,
        .elevation_first_m = 793,
        .elevation_last_m = 793,
    });
}

test "grp-120-2026.gpx: one LifeBase, two stages" {
    try fixture_check(@embedFile("grp-120-2026.gpx"), &.{
        .name = "GRP 2026 Tour des Cirques",
        .points = 5536,
        .time_barriers = 8,
        .life_bases = 1,
        .start_s = 1787288400,
        .arrival_s = 1787436000,
        .distance_km_reference = 125.8,
        .elevation_first_m = 1862,
        .elevation_last_m = 792,
    });
}

test "grp-160-2026.gpx: the largest file, two LifeBases, three stages" {
    try fixture_check(@embedFile("grp-160-2026.gpx"), &.{
        .name = "GRP 2026 Ultra Tour",
        .points = 30899,
        .time_barriers = 11,
        .life_bases = 2,
        .start_s = 1787281200,
        .arrival_s = 1787461200,
        .distance_km_reference = 174.7,
        .elevation_first_m = 791,
        .elevation_last_m = 792,
    });
}

/// Reads the waypoints of `bytes`, writes them back and reads again: the same route and the
/// same plan, and nothing but the waypoints touched.
fn round_trip_check(bytes: []const u8) !void {
    assert(bytes.len > 0);
    var before = try gpxz.parse(testing.allocator, bytes, &.{});
    defer before.deinit(testing.allocator);

    const written = try gpxz.waypoints_replace(testing.allocator, bytes, before.waypoints);
    defer testing.allocator.free(written);
    var after = try gpxz.parse(testing.allocator, written, &.{});
    defer after.deinit(testing.allocator);

    // The track is the same bytes' worth of points, and the waypoints are the same.
    try testing.expectEqualSlices(f64, before.points_full_resolution, after.points_full_resolution);
    try testing.expectEqual(before.waypoints.len, after.waypoints.len);
    for (before.waypoints, after.waypoints) |expected, actual| {
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqual(expected.latitude, actual.latitude);
        try testing.expectEqual(expected.longitude, actual.longitude);
        try testing.expectEqual(expected.elevation_m, actual.elevation_m);
        try testing.expectEqual(expected.epoch_s, actual.epoch_s);
        try testing.expectEqualDeep(expected.type_name, actual.type_name);
    }

    // So the plan gpxz derives is the same, to the last bit.
    try testing.expectEqual(before.trace.distance_m, after.trace.distance_m);
    try testing.expectEqual(before.plan.?.len, after.plan.?.len);
    for (before.plan.?, after.plan.?) |expected, actual| {
        try testing.expectEqual(expected.distance_m, actual.distance_m);
        try testing.expectEqual(expected.duration_s_arrival, actual.duration_s_arrival);
        try testing.expectEqual(expected.epoch_s_cutoff, actual.epoch_s_cutoff);
    }

    // Everything but the waypoints is the original's: with the waypoints taken out of both,
    // the files are the same.
    const bare_before = try gpxz.waypoints_replace(testing.allocator, bytes, &.{});
    defer testing.allocator.free(bare_before);
    const bare_after = try gpxz.waypoints_replace(testing.allocator, written, &.{});
    defer testing.allocator.free(bare_after);
    try testing.expectEqualStrings(bare_before, bare_after);
}

test "every fixture: its waypoints written back leave the route and the plan as they were" {
    inline for (.{
        "grp-40-gela-2026.gpx",
        "grp-40-neouvielle-2026.gpx",
        "grp-50-2026.gpx",
        "grp-60-2026.gpx",
        "grp-80-2026.gpx",
        "grp-120-2026.gpx",
        "grp-160-2026.gpx",
    }) |name| {
        try round_trip_check(@embedFile(name));
    }
}
