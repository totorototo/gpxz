//! GPX parsing by scanning bytes with std.mem: no XML library. It reads what gpxz needs
//! (track points, waypoints, metadata name and description) and rejects malformed elements
//! with an error instead of skipping them: a skipped point would silently shorten a route.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Trace = @import("trace.zig").Trace;
const gpx_data = @import("gpx_data.zig");
const Waypoint = gpx_data.Waypoint;
const GPXData = gpx_data.GPXData;
const Metadata = gpx_data.Metadata;
const leg = @import("leg.zig");
const section = @import("section.zig");
const stage = @import("stage.zig");
const time = @import("time.zig");
const pace_model = @import("pace_model.zig");
const calibration = @import("calibration.zig");

pub const ParseError = error{
    /// An element or its opening tag never closes.
    ElementUnclosed,
    /// An attribute value isn't quoted.
    AttributeInvalid,
    /// A `lat` or `lon` is missing, isn't a number, or is out of range.
    CoordinateInvalid,
    /// A track point has no `<ele>`: gpxz needs elevation for every point.
    ElevationMissing,
    /// An `<ele>` or `<stopDuration>` isn't a finite number.
    NumberInvalid,
    /// A `<time>` isn't an ISO 8601 UTC or offset timestamp.
    TimeInvalid,
};

/// Parses a GPX file and computes everything gpxz derives from it. The caller owns the
/// result and frees it with `deinit`.
pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    settings: *const pace_model.Settings,
) (ParseError || std.mem.Allocator.Error)!GPXData {
    settings.assert_valid();
    var metadata = try metadata_read(allocator, bytes);
    errdefer metadata.deinit(allocator);
    const points = try trace_points_read(allocator, bytes);
    errdefer allocator.free(points);
    const waypoints = try waypoints_read(allocator, bytes);
    errdefer waypoints_free(allocator, waypoints);

    // Trace.init copies the points; the originals stay for full-resolution rendering.
    var trace = try Trace.init(allocator, points);
    errdefer trace.deinit(allocator);
    const legs: ?[]const leg.LegStats = if (waypoints.len > 1)
        try leg.legs_compute(allocator, &trace, waypoints)
    else
        null;
    errdefer if (legs) |slice| allocator.free(slice);
    const sections = try section.sections_compute(allocator, &trace, waypoints, settings);
    errdefer if (sections) |slice| allocator.free(slice);
    const stages = try stage.stages_compute(allocator, &trace, waypoints, settings);
    // Trace.init only ever drops points, when it simplifies.
    assert(trace.points.len <= points.len);
    if (legs) |slice| assert(slice.len < waypoints.len);

    return .{
        .trace = trace,
        .waypoints = waypoints,
        .legs = legs,
        .sections = sections,
        .stages = stages,
        .metadata = metadata,
        // The same allocation seen as flat f64s: [3]f64 has no padding, so the byte length
        // and alignment match and GPXData.deinit frees it as is.
        .points_full_resolution = @as([*]f64, @ptrCast(points.ptr))[0 .. points.len * 3],
    };
}

/// Returns every `<trkpt>` as [lat, lon, ele], in file order. The caller owns the result.
pub fn trace_points_read(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (ParseError || std.mem.Allocator.Error)![][3]f64 {
    var points: std.ArrayList([3]f64) = .empty;
    defer points.deinit(allocator);
    var position: usize = 0;
    while (try element_next(bytes, position, "trkpt")) |element| {
        assert(element.end > position);
        position = element.end;
        const coordinates = try coordinates_parse(element.attributes);
        const elevation_text = try child_text(element.content, "ele") orelse
            return error.ElevationMissing;
        const elevation_m = try number_parse(elevation_text);
        try points.append(allocator, .{ coordinates[0], coordinates[1], elevation_m });
    }
    // Every point passed coordinates_parse: gps_point asserts the same range on each.
    for (points.items) |point| assert(coordinates_valid(point[0], point[1]));
    return points.toOwnedSlice(allocator);
}

/// Returns every `<wpt>`, in file order. The caller owns the result and frees it with
/// `waypoints_free`.
pub fn waypoints_read(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (ParseError || std.mem.Allocator.Error)![]Waypoint {
    var waypoints: std.ArrayList(Waypoint) = .empty;
    defer waypoints.deinit(allocator);
    errdefer for (waypoints.items) |*waypoint| waypoint.deinit(allocator);
    var position: usize = 0;
    while (try element_next(bytes, position, "wpt")) |element| {
        assert(element.end > position);
        position = element.end;
        var waypoint = try waypoint_parse(allocator, &element);
        errdefer waypoint.deinit(allocator);
        assert(coordinates_valid(waypoint.latitude, waypoint.longitude));
        try waypoints.append(allocator, waypoint);
    }
    return waypoints.toOwnedSlice(allocator);
}

pub fn waypoints_free(allocator: std.mem.Allocator, waypoints: []Waypoint) void {
    for (waypoints) |*waypoint| waypoint.deinit(allocator);
    allocator.free(waypoints);
}

fn waypoint_parse(
    allocator: std.mem.Allocator,
    element: *const Element,
) (ParseError || std.mem.Allocator.Error)!Waypoint {
    const coordinates = try coordinates_parse(element.attributes);
    const content = element.content;
    var waypoint: Waypoint = .{
        .latitude = coordinates[0],
        .longitude = coordinates[1],
        .name = try allocator.dupe(u8, try child_text(content, "name") orelse ""),
        .epoch_s = null,
    };
    errdefer waypoint.deinit(allocator);

    if (try child_text(content, "ele")) |text| waypoint.elevation_m = try number_parse(text);
    if (try child_text(content, "time")) |text| {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        waypoint.epoch_s = time.iso8601_to_epoch_s(trimmed) catch return error.TimeInvalid;
    }
    if (try child_text(content, "stopDuration")) |text| {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        waypoint.stop_s = std.fmt.parseInt(u32, trimmed, 10) catch return error.NumberInvalid;
    }
    waypoint.description = try child_dupe(allocator, content, "desc");
    waypoint.comment = try child_dupe(allocator, content, "cmt");
    waypoint.symbol = try child_dupe(allocator, content, "sym");
    waypoint.type_name = try child_dupe(allocator, content, "type");
    assert(waypoint.name.len <= content.len);
    return waypoint;
}

/// Returns the route's name and description: from `<metadata>` (GPX 1.1), or else the first
/// `<name>` and `<desc>` in the file (GPX 1.0 puts them under `<gpx>`). The caller owns the
/// result.
pub fn metadata_read(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (ParseError || std.mem.Allocator.Error)!Metadata {
    const region = if (try element_next(bytes, 0, "metadata")) |element|
        element.content
    else
        bytes;
    assert(region.len <= bytes.len);
    var metadata: Metadata = .{ .name = null, .description = null };
    errdefer metadata.deinit(allocator);
    metadata.name = try child_dupe(allocator, region, "name");
    metadata.description = try child_dupe(allocator, region, "desc");
    return metadata;
}

const Element = struct {
    /// Between the element name and the end of the opening tag.
    attributes: []const u8,
    /// Between the opening and closing tags; empty for a self-closing element.
    content: []const u8,
    /// The index just past the element.
    end: usize,
};

/// Returns the first `<name ...>` element at or after `position`, or null when there is none.
fn element_next(
    bytes: []const u8,
    position: usize,
    comptime name: []const u8,
) ParseError!?Element {
    const open = "<" ++ name;
    var search = position;
    // Bounded: each iteration moves `search` forward.
    const start = while (std.mem.indexOfPos(u8, bytes, search, open)) |found| {
        const after = found + open.len;
        // `<trkpt` must not match `<trkptx`: the name ends at whitespace, `>` or `/`.
        if (after < bytes.len and name_ends(bytes[after])) break found;
        search = after;
    } else return null;
    const attributes_start = start + open.len;
    const tag_end = std.mem.indexOfScalarPos(u8, bytes, attributes_start, '>') orelse
        return error.ElementUnclosed;
    assert(tag_end >= attributes_start);
    if (bytes[tag_end - 1] == '/') {
        return .{
            .attributes = bytes[attributes_start .. tag_end - 1],
            .content = "",
            .end = tag_end + 1,
        };
    }
    const close = "</" ++ name ++ ">";
    const close_start = std.mem.indexOfPos(u8, bytes, tag_end + 1, close) orelse
        return error.ElementUnclosed;
    const element: Element = .{
        .attributes = bytes[attributes_start..tag_end],
        .content = bytes[tag_end + 1 .. close_start],
        .end = close_start + close.len,
    };
    assert(element.end > position);
    return element;
}

fn name_ends(character: u8) bool {
    return character == '>' or character == '/' or std.ascii.isWhitespace(character);
}

/// Returns the text of the first `<name>` child in `content`, or null when there is none.
fn child_text(content: []const u8, comptime name: []const u8) ParseError!?[]const u8 {
    const open = "<" ++ name ++ ">";
    const close = "</" ++ name ++ ">";
    const open_start = std.mem.indexOf(u8, content, open) orelse return null;
    const text_start = open_start + open.len;
    const text_end = std.mem.indexOfPos(u8, content, text_start, close) orelse
        return error.ElementUnclosed;
    assert(text_end >= text_start);
    return content[text_start..text_end];
}

/// Returns an owned copy of the first `<name>` child's text, or null when there is none.
fn child_dupe(
    allocator: std.mem.Allocator,
    content: []const u8,
    comptime name: []const u8,
) (ParseError || std.mem.Allocator.Error)!?[]const u8 {
    const text = try child_text(content, name) orelse return null;
    return try allocator.dupe(u8, text);
}

/// Returns the value of attribute `name`, quoted with `"` or `'`, or null when absent.
fn attribute_value(attributes: []const u8, comptime name: []const u8) ParseError!?[]const u8 {
    const key = name ++ "=";
    var search: usize = 0;
    const start = while (std.mem.indexOfPos(u8, attributes, search, key)) |found| {
        // `lat=` must not match `xlat=`.
        if (found > 0 and std.ascii.isWhitespace(attributes[found - 1])) break found;
        search = found + key.len;
    } else return null;
    const quote_index = start + key.len;
    if (quote_index >= attributes.len) return error.AttributeInvalid;
    const quote = attributes[quote_index];
    if (quote != '"' and quote != '\'') return error.AttributeInvalid;
    const value_end = std.mem.indexOfScalarPos(u8, attributes, quote_index + 1, quote) orelse
        return error.AttributeInvalid;
    assert(value_end > quote_index and value_end < attributes.len);
    return attributes[quote_index + 1 .. value_end];
}

/// Returns [lat, lon] from an element's attributes, both required and in range.
fn coordinates_parse(attributes: []const u8) ParseError![2]f64 {
    const latitude_text = try attribute_value(attributes, "lat") orelse
        return error.CoordinateInvalid;
    const longitude_text = try attribute_value(attributes, "lon") orelse
        return error.CoordinateInvalid;
    const latitude = number_parse(latitude_text) catch return error.CoordinateInvalid;
    const longitude = number_parse(longitude_text) catch return error.CoordinateInvalid;
    if (!coordinates_valid(latitude, longitude)) return error.CoordinateInvalid;
    return .{ latitude, longitude };
}

fn coordinates_valid(latitude: f64, longitude: f64) bool {
    return latitude >= -90.0 and latitude <= 90.0 and longitude >= -180.0 and longitude <= 180.0;
}

/// Parses a finite decimal number, ignoring surrounding whitespace, which XML allows.
fn number_parse(text: []const u8) ParseError!f64 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    const value = std.fmt.parseFloat(f64, trimmed) catch return error.NumberInvalid;
    // parseFloat accepts "nan" and "inf", which no GPX coordinate or elevation can be.
    if (!std.math.isFinite(value)) return error.NumberInvalid;
    assert(!std.math.isNan(value));
    return value;
}

/// Section and stage recalibration of one route. Either is null when the route has fewer
/// than two boundaries of that kind. Legs have no cutoff to calibrate against.
pub const RecalibrationPair = struct {
    section: ?calibration.Recalibration,
    stage: ?calibration.Recalibration,

    pub fn deinit(self: *RecalibrationPair, allocator: std.mem.Allocator) void {
        if (self.section) |*recalibration| recalibration.deinit(allocator);
        if (self.stage) |*recalibration| recalibration.deinit(allocator);
        self.* = undefined;
    }
};

/// A parsed route that outlives one call, so live recalibration can run at every GPS fix
/// without parsing the GPX again. terminus's worker keeps one per loaded file.
pub const Route = struct {
    trace: Trace,
    waypoints: []Waypoint,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Route {
        const points = try trace_points_read(allocator, bytes);
        defer allocator.free(points);
        const waypoints = try waypoints_read(allocator, bytes);
        errdefer waypoints_free(allocator, waypoints);
        const trace = try Trace.init(allocator, points);
        assert(trace.points.len <= points.len);
        return .{ .trace = trace, .waypoints = waypoints };
    }

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        self.trace.deinit(allocator);
        waypoints_free(allocator, self.waypoints);
        self.* = undefined;
    }

    /// Recalibrates section and stage ETAs from the runner's progress. See
    /// `calibration.recalibrate`. The caller owns the result.
    pub fn recalibrate(
        self: *const Route,
        allocator: std.mem.Allocator,
        index_current: usize,
        elapsed_s_actual: f64,
        settings: *const pace_model.Settings,
    ) !RecalibrationPair {
        var sections = try section.recalibrate(
            allocator,
            &self.trace,
            self.waypoints,
            index_current,
            elapsed_s_actual,
            settings,
        );
        errdefer if (sections) |*recalibration| recalibration.deinit(allocator);
        const stages = try stage.recalibrate(
            allocator,
            &self.trace,
            self.waypoints,
            index_current,
            elapsed_s_actual,
            settings,
        );
        return .{ .section = sections, .stage = stages };
    }
};

/// Parses `bytes`, recalibrates, and frees the parse: for callers without a resident Route.
pub fn recalibrate_bytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    index_current: usize,
    elapsed_s_actual: f64,
    settings: *const pace_model.Settings,
) !RecalibrationPair {
    var route = try Route.init(allocator, bytes);
    defer route.deinit(allocator);
    return route.recalibrate(allocator, index_current, elapsed_s_actual, settings);
}

fn parse_test(bytes: []const u8) !GPXData {
    return parse(testing.allocator, bytes, &.{});
}

test "parse: track points and waypoints" {
    const bytes =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<gpx version="1.1">
        \\ <wpt lat="45.000000" lon="7.000000">
        \\  <name>Checkpoint 10km</name>
        \\  <time>2025-11-20T12:00:00Z</time>
        \\ </wpt>
        \\ <wpt lat="45.010000" lon="7.010000"><name>Checkpoint 20km</name></wpt>
        \\ <trk><trkseg>
        \\  <trkpt lat="45.000000" lon="7.000000"><ele>300</ele></trkpt>
        \\  <trkpt lat="45.005000" lon="7.005000"><ele>320</ele></trkpt>
        \\  <trkpt lat="45.010000" lon="7.010000"><ele>340</ele></trkpt>
        \\ </trkseg></trk>
        \\</gpx>
    ;
    var data = try parse_test(bytes);
    defer data.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), data.trace.points.len);
    try testing.expectEqual([3]f64{ 45.0, 7.0, 300.0 }, data.trace.points[0]);
    try testing.expectEqual(@as(usize, 9), data.points_full_resolution.len);
    try testing.expectEqual(@as(f64, 340.0), data.points_full_resolution[8]);
    try testing.expectEqual(@as(usize, 2), data.waypoints.len);
    try testing.expectEqualStrings("Checkpoint 10km", data.waypoints[0].name);
    try testing.expectEqual(@as(?i64, 1763640000), data.waypoints[0].epoch_s);
    try testing.expectEqual(@as(?i64, null), data.waypoints[1].epoch_s);
    try testing.expectEqual(@as(usize, 1), data.legs.?.len);
    // No typed waypoints: no sections or stages.
    try testing.expectEqual(@as(?[]const section.SectionStats, null), data.sections);
    try testing.expectEqual(@as(?[]const stage.StageStats, null), data.stages);
}

test "parse: legs are null with fewer than 2 waypoints" {
    const no_waypoint =
        \\<gpx><trk><trkseg>
        \\ <trkpt lat="45.0" lon="7.0"><ele>100</ele></trkpt>
        \\ <trkpt lat="45.1" lon="7.1"><ele>110</ele></trkpt>
        \\</trkseg></trk></gpx>
    ;
    var none = try parse_test(no_waypoint);
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const leg.LegStats, null), none.legs);

    const one_waypoint =
        \\<gpx><wpt lat="45.0" lon="7.0"><name>A</name></wpt><trk><trkseg>
        \\ <trkpt lat="45.0" lon="7.0"><ele>100</ele></trkpt>
        \\ <trkpt lat="45.1" lon="7.1"><ele>110</ele></trkpt>
        \\</trkseg></trk></gpx>
    ;
    var one = try parse_test(one_waypoint);
    defer one.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const leg.LegStats, null), one.legs);
}

test "parse: an empty file has an empty trace" {
    var data = try parse_test("");
    defer data.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), data.trace.points.len);
    try testing.expectEqual(@as(usize, 0), data.waypoints.len);
    try testing.expectEqual(@as(?[]const u8, null), data.metadata.name);
}

test "trace_points_read: quotes, signs, precision, scientific notation, and whitespace" {
    const bytes =
        \\<trkseg>
        \\ <trkpt lat='45.1' lon='7.1'><ele>100</ele></trkpt>
        \\ <trkpt lat="-33.8688" lon="-151.2093"><ele>-10.5</ele></trkpt>
        \\ <trkpt lat="45.123456789012" lon="7.1"><ele>8848.86</ele></trkpt>
        \\ <trkpt lat="4.5e1" lon="7.1e0"><ele>1e2</ele></trkpt>
        \\ <trkpt  lon="7.2"   lat="45.2" ><ele> 120 </ele></trkpt>
        \\</trkseg><trkseg>
        \\ <trkpt lat="90" lon="-180"><ele>0</ele></trkpt>
        \\</trkseg>
    ;
    const points = try trace_points_read(testing.allocator, bytes);
    defer testing.allocator.free(points);
    const expected = [_][3]f64{
        .{ 45.1, 7.1, 100.0 },
        .{ -33.8688, -151.2093, -10.5 },
        .{ 45.123456789012, 7.1, 8848.86 },
        .{ 45.0, 7.1, 100.0 },
        .{ 45.2, 7.2, 120.0 },
        .{ 90.0, -180.0, 0.0 },
    };
    try testing.expectEqualSlices([3]f64, &expected, points);
}

test "trace_points_read: no track points" {
    for ([_][]const u8{ "", "<gpx><trk><trkseg></trkseg></trk></gpx>" }) |bytes| {
        const points = try trace_points_read(testing.allocator, bytes);
        defer testing.allocator.free(points);
        try testing.expectEqual(@as(usize, 0), points.len);
    }
}

test "trace_points_read: `<trkseg>` and `<trkptx>` aren't track points" {
    const bytes = "<trkseg><trkptx lat=\"1\" lon=\"1\"></trkptx></trkseg>";
    const points = try trace_points_read(testing.allocator, bytes);
    defer testing.allocator.free(points);
    try testing.expectEqual(@as(usize, 0), points.len);
}

/// A track point element with these attribute and elevation texts.
fn trkpt_test(
    comptime latitude: []const u8,
    comptime longitude: []const u8,
    comptime elevation: []const u8,
) []const u8 {
    return "<trkpt lat=\"" ++ latitude ++ "\" lon=\"" ++ longitude ++ "\"><ele>" ++ elevation ++
        "</ele></trkpt>";
}

test "trace_points_read: malformed points are errors, not skipped" {
    const Case = struct { bytes: []const u8, err: ParseError };
    const cases = [_]Case{
        .{ .bytes = "<trkpt lon=\"7\"><ele>1</ele></trkpt>", .err = error.CoordinateInvalid },
        .{ .bytes = trkpt_test("x", "7", "1"), .err = error.CoordinateInvalid },
        .{ .bytes = trkpt_test("nan", "7", "1"), .err = error.CoordinateInvalid },
        .{ .bytes = trkpt_test("90.1", "7", "1"), .err = error.CoordinateInvalid },
        .{ .bytes = trkpt_test("45", "180.5", "1"), .err = error.CoordinateInvalid },
        .{ .bytes = "<trkpt lat=45 lon=\"7\"><ele>1</ele></trkpt>", .err = error.AttributeInvalid },
        // An unclosed quote swallows the next attribute.
        .{ .bytes = trkpt_test("45 lon=", "7", "1"), .err = error.CoordinateInvalid },
        .{ .bytes = "<trkpt lat=\"45\" lon=\"7\"></trkpt>", .err = error.ElevationMissing },
        .{ .bytes = "<trkpt lat=\"45\" lon=\"7\"/>", .err = error.ElevationMissing },
        .{ .bytes = trkpt_test("45", "7", "high"), .err = error.NumberInvalid },
        .{ .bytes = trkpt_test("45", "7", "inf"), .err = error.NumberInvalid },
        .{ .bytes = "<trkpt lat=\"45\" lon=\"7\"><ele>1</ele>", .err = error.ElementUnclosed },
        .{ .bytes = "<trkpt lat=\"45\" lon=\"7\"><ele>1</trkpt>", .err = error.ElementUnclosed },
        .{ .bytes = "<trkpt lat=\"45\" lon=\"7\"", .err = error.ElementUnclosed },
    };
    for (cases) |case| {
        try testing.expectError(case.err, trace_points_read(testing.allocator, case.bytes));
    }
}

test "waypoints_read: every field" {
    const bytes =
        \\<wpt lat="45.0" lon="7.0">
        \\ <ele> 1200.5 </ele>
        \\ <name>LB1</name>
        \\ <desc>Hot food</desc>
        \\ <cmt>Crew allowed</cmt>
        \\ <sym>Flag</sym>
        \\ <type>LifeBase</type>
        \\ <time>2025-11-20T13:00:00+01:00</time>
        \\ <stopDuration>3600</stopDuration>
        \\</wpt>
        \\<wpt lat='45.1' lon='7.1'/>
    ;
    const waypoints = try waypoints_read(testing.allocator, bytes);
    defer waypoints_free(testing.allocator, waypoints);

    try testing.expectEqual(@as(usize, 2), waypoints.len);
    const full = waypoints[0];
    try testing.expectEqual(@as(f64, 45.0), full.latitude);
    try testing.expectEqual(@as(?f64, 1200.5), full.elevation_m);
    try testing.expectEqualStrings("LB1", full.name);
    try testing.expectEqualStrings("Hot food", full.description.?);
    try testing.expectEqualStrings("Crew allowed", full.comment.?);
    try testing.expectEqualStrings("Flag", full.symbol.?);
    try testing.expectEqualStrings("LifeBase", full.type_name.?);
    try testing.expectEqual(@as(?i64, 1763640000), full.epoch_s);
    try testing.expectEqual(@as(?u32, 3600), full.stop_s);

    // Self-closing, with nothing but coordinates.
    const bare = waypoints[1];
    try testing.expectEqual(@as(f64, 45.1), bare.latitude);
    try testing.expectEqualStrings("", bare.name);
    try testing.expectEqual(@as(?f64, null), bare.elevation_m);
    try testing.expectEqual(@as(?[]const u8, null), bare.type_name);
    try testing.expectEqual(@as(?u32, null), bare.stop_s);
}

test "waypoints_read: a child belongs to its own waypoint only" {
    const bytes =
        \\<wpt lat="45.0" lon="7.0"><name>First</name></wpt>
        \\<wpt lat="45.1" lon="7.1"><name>Second</name><desc>Only second</desc></wpt>
    ;
    const waypoints = try waypoints_read(testing.allocator, bytes);
    defer waypoints_free(testing.allocator, waypoints);
    try testing.expectEqual(@as(?[]const u8, null), waypoints[0].description);
    try testing.expectEqualStrings("Only second", waypoints[1].description.?);
}

test "waypoints_read: empty elements are empty strings" {
    const bytes = "<wpt lat=\"45.0\" lon=\"7.0\"><name></name><desc></desc></wpt>";
    const waypoints = try waypoints_read(testing.allocator, bytes);
    defer waypoints_free(testing.allocator, waypoints);
    try testing.expectEqualStrings("", waypoints[0].name);
    try testing.expectEqualStrings("", waypoints[0].description.?);
}

test "waypoints_read: malformed waypoints are errors, not skipped" {
    const Case = struct { bytes: []const u8, err: ParseError };
    const cases = [_]Case{
        .{ .bytes = "<wpt lon=\"7.1\"><name>No lat</name></wpt>", .err = error.CoordinateInvalid },
        .{ .bytes = "<wpt lat=\"bad\" lon=\"7.3\"></wpt>", .err = error.CoordinateInvalid },
        .{ .bytes = "<wpt lat=\"45\" lon=\"7\"><ele>x</ele></wpt>", .err = error.NumberInvalid },
        .{ .bytes = "<wpt lat=\"45\" lon=\"7\"><time>noon</time></wpt>", .err = error.TimeInvalid },
        .{
            .bytes = "<wpt lat=\"45\" lon=\"7\"><stopDuration>-5</stopDuration></wpt>",
            .err = error.NumberInvalid,
        },
        .{ .bytes = "<wpt lat=\"45\" lon=\"7\"><name>Open</wpt>", .err = error.ElementUnclosed },
        .{ .bytes = "<wpt lat=\"45\" lon=\"7\"><name>A</name>", .err = error.ElementUnclosed },
    };
    for (cases) |case| {
        try testing.expectError(case.err, waypoints_read(testing.allocator, case.bytes));
    }
}

test "waypoints_read: an error partway frees what was already read" {
    const bytes =
        \\<wpt lat="45.0" lon="7.0"><name>Good</name><desc>Kept until the error</desc></wpt>
        \\<wpt lat="45.1" lon="7.1"><name>Good too</name><time>bad</time></wpt>
    ;
    // testing.allocator fails the test on a leak.
    try testing.expectError(error.TimeInvalid, waypoints_read(testing.allocator, bytes));
}

test "metadata_read: from <metadata>, from the root, or none" {
    const in_metadata =
        \\<gpx><metadata>
        \\ <name>My Trail Run</name>
        \\ <desc>A mountain trail</desc>
        \\</metadata><trk><name>Track name</name></trk></gpx>
    ;
    var metadata = try metadata_read(testing.allocator, in_metadata);
    defer metadata.deinit(testing.allocator);
    try testing.expectEqualStrings("My Trail Run", metadata.name.?);
    try testing.expectEqualStrings("A mountain trail", metadata.description.?);

    var root = try metadata_read(testing.allocator, "<gpx><name>Root Level Name</name></gpx>");
    defer root.deinit(testing.allocator);
    try testing.expectEqualStrings("Root Level Name", root.name.?);
    try testing.expectEqual(@as(?[]const u8, null), root.description);

    var none = try metadata_read(testing.allocator, "<gpx><trk><trkseg></trkseg></trk></gpx>");
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), none.name);

    try testing.expectError(error.ElementUnclosed, metadata_read(testing.allocator, "<metadata>"));
}

test "attribute_value: requires whitespace before the name and a quote after it" {
    try testing.expectEqualStrings("1", (try attribute_value(" lat=\"1\"", "lat")).?);
    try testing.expectEqualStrings("2", (try attribute_value(" xlat=\"9\" lat='2'", "lat")).?);
    try testing.expectEqual(@as(?[]const u8, null), try attribute_value(" xlat=\"9\"", "lat"));
    try testing.expectEqual(@as(?[]const u8, null), try attribute_value("", "lat"));
    try testing.expectError(error.AttributeInvalid, attribute_value(" lat=", "lat"));
    try testing.expectError(error.AttributeInvalid, attribute_value(" lat=\"1", "lat"));
}

/// Start, TimeBarrier, LifeBase and Arrival on track points, so boundaries resolve cleanly.
const route_bytes =
    \\<gpx>
    \\ <trk><trkseg>
    \\  <trkpt lat="45.000" lon="7.000"><ele>100</ele></trkpt>
    \\  <trkpt lat="45.005" lon="7.005"><ele>105</ele></trkpt>
    \\  <trkpt lat="45.010" lon="7.010"><ele>110</ele></trkpt>
    \\  <trkpt lat="45.015" lon="7.015"><ele>115</ele></trkpt>
    \\  <trkpt lat="45.020" lon="7.020"><ele>120</ele></trkpt>
    \\  <trkpt lat="45.030" lon="7.030"><ele>130</ele></trkpt>
    \\  <trkpt lat="45.040" lon="7.040"><ele>140</ele></trkpt>
    \\ </trkseg></trk>
    \\ <wpt lat="45.000" lon="7.000"><name>Start</name><type>Start</type></wpt>
    \\ <wpt lat="45.010" lon="7.010"><name>TB1</name><type>TimeBarrier</type></wpt>
    \\ <wpt lat="45.020" lon="7.020"><name>LB1</name><type>LifeBase</type></wpt>
    \\ <wpt lat="45.040" lon="7.040"><name>Finish</name><type>Arrival</type></wpt>
    \\</gpx>
;

test "recalibrate_bytes: three sections and two stages" {
    var pair = try recalibrate_bytes(testing.allocator, route_bytes, 0, 0.0, &.{});
    defer pair.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), pair.section.?.etas.len);
    try testing.expectEqual(@as(f64, 1.0), pair.section.?.calibration_factor);
    try testing.expectEqual(@as(usize, 2), pair.stage.?.etas.len);
}

test "Route: repeated recalibrations match the one-shot path" {
    var route = try Route.init(testing.allocator, route_bytes);
    defer route.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 7), route.trace.points.len);
    try testing.expectEqual(@as(usize, 4), route.waypoints.len);

    var first = try route.recalibrate(testing.allocator, 0, 0.0, &.{});
    defer first.deinit(testing.allocator);
    var second = try route.recalibrate(testing.allocator, 2, 600.0, &.{});
    defer second.deinit(testing.allocator);
    var one_shot = try recalibrate_bytes(testing.allocator, route_bytes, 2, 600.0, &.{});
    defer one_shot.deinit(testing.allocator);

    const expected = one_shot.section.?;
    const actual = second.section.?;
    try testing.expectEqual(expected.calibration_factor, actual.calibration_factor);
    try testing.expectEqualSlices(calibration.RecalibratedETA, expected.etas, actual.etas);
    const ETA = calibration.RecalibratedETA;
    try testing.expectEqualSlices(ETA, one_shot.stage.?.etas, second.stage.?.etas);
}

test "recalibrate_bytes: null with fewer than two boundaries" {
    const bytes =
        \\<gpx><trk><trkseg>
        \\ <trkpt lat="45.000" lon="7.000"><ele>100</ele></trkpt>
        \\ <trkpt lat="45.010" lon="7.010"><ele>110</ele></trkpt>
        \\</trkseg></trk>
        \\<wpt lat="45.000" lon="7.000"><name>Start</name><type>Start</type></wpt></gpx>
    ;
    var pair = try recalibrate_bytes(testing.allocator, bytes, 0, 0.0, &.{});
    defer pair.deinit(testing.allocator);
    try testing.expectEqual(@as(?calibration.Recalibration, null), pair.section);
    try testing.expectEqual(@as(?calibration.Recalibration, null), pair.stage);
}
