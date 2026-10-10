//! GPX writing: a file with its waypoints replaced. Only the `<wpt>` elements change; the
//! track, the metadata and whatever extensions the tool that wrote the file added stay as
//! they were, byte for byte. Re-serializing the file from what gpxz parsed would lose all
//! that gpxz does not read.
//!
//! The waypoints are written as the files this library reads have them:
//!
//! ```xml
//! <wpt lat="42.829760" lon="0.327362">
//!   <ele>791</ele>
//!   <name>Vielle-Aure</name>
//!   <type>Start</type>
//!   <time>2026-08-21T03:00:00Z</time>
//!   <stopDuration>3600</stopDuration>
//! </wpt>
//! ```
//!
//! `<stopDuration>` (seconds) is not GPX 1.1: gpxz reads it as the planned stop, and other
//! tools ignore it.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const gpx = @import("gpx.zig");
const gpx_data = @import("gpx_data.zig");
const Waypoint = gpx_data.Waypoint;
const time = @import("time.zig");
const xml_text = @import("xml_text.zig");

pub const WriteError = error{
    /// The text has no `</gpx>`: it is not a GPX file, so there is nowhere to put waypoints.
    NotGpx,
    /// A waypoint's `lat` or `lon` is not a number in range.
    CoordinateInvalid,
    /// A waypoint's `<ele>` is not a finite number.
    NumberInvalid,
    /// A waypoint's `<time>` is outside year 0000 to 9999: it has no four-digit form.
    TimeOutOfRange,
};

/// Returns `bytes` with its `<wpt>` elements replaced by `waypoints`, in memory the caller
/// owns. The new ones go where GPX 1.1 puts waypoints: after `<metadata>`, before the routes
/// and tracks, whatever the old ones' place was. The file's line endings are kept.
///
/// The waypoints are written in the order given, and that order is meaningful: gpxz matches
/// each waypoint to the track after the previous one, so they must be in route order.
///
/// A file whose `<wpt>` is malformed is rejected as `parse` rejects it, so a half-read file
/// is never half-written.
pub fn waypoints_replace(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    waypoints: []const Waypoint,
) (WriteError || gpx.ParseError || std.mem.Allocator.Error)![]u8 {
    if (std.mem.lastIndexOf(u8, bytes, "</gpx") == null) return error.NotGpx;
    // Checked before anything is built: a bad waypoint fails without a half-made file.
    for (waypoints) |*waypoint| try waypoint_check(waypoint);

    const without = try waypoints_remove(allocator, bytes);
    defer allocator.free(without);
    const insert_at = try insertion_point(without);
    assert(insert_at <= without.len);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const newline = newline_detect(bytes);
    out.writer.writeAll(without[0..insert_at]) catch return error.OutOfMemory;
    for (waypoints) |*waypoint| {
        waypoint_write(&out.writer, waypoint, newline) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |write_error| return write_error,
        };
        out.writer.writeAll(newline) catch return error.OutOfMemory;
    }
    out.writer.writeAll(without[insert_at..]) catch return error.OutOfMemory;

    const result = try out.toOwnedSlice();
    errdefer allocator.free(result);
    // Paired with the removal: every waypoint is in the file once, and no old one is left.
    assert(waypoints_count(result) == waypoints.len);
    return result;
}

/// Whether `waypoint` can be written: a position in range, a finite elevation, a time that
/// has a four-digit year.
fn waypoint_check(waypoint: *const Waypoint) WriteError!void {
    if (!std.math.isFinite(waypoint.latitude) or !std.math.isFinite(waypoint.longitude) or
        !gpx.coordinates_valid(waypoint.latitude, waypoint.longitude))
    {
        return error.CoordinateInvalid;
    }
    if (waypoint.elevation_m) |elevation_m| {
        if (!std.math.isFinite(elevation_m)) return error.NumberInvalid;
    }
    if (waypoint.epoch_s) |epoch_s| {
        if (epoch_s < time.epoch_s_min or epoch_s > time.epoch_s_max) return error.TimeOutOfRange;
    }
}

/// Writes one `<wpt>` element, without a newline after it. Lines inside it end with
/// `newline`.
pub fn waypoint_write(
    writer: *std.Io.Writer,
    waypoint: *const Waypoint,
    newline: []const u8,
) (WriteError || std.Io.Writer.Error)!void {
    assert(newline.len == 1 or newline.len == 2);
    try waypoint_check(waypoint);
    try writer.print("<wpt lat=\"{d}\" lon=\"{d}\">{s}", .{
        waypoint.latitude,
        waypoint.longitude,
        newline,
    });
    if (waypoint.elevation_m) |elevation_m| {
        try writer.print("  <ele>{d}</ele>{s}", .{ elevation_m, newline });
    }
    try text_element_write(writer, "name", waypoint.name, newline);
    if (waypoint.description) |text| try text_element_write(writer, "desc", text, newline);
    if (waypoint.comment) |text| try text_element_write(writer, "cmt", text, newline);
    if (waypoint.symbol) |text| try text_element_write(writer, "sym", text, newline);
    if (waypoint.type_name) |text| try text_element_write(writer, "type", text, newline);
    if (waypoint.epoch_s) |epoch_s| {
        const timestamp = time.epoch_s_to_iso8601(epoch_s) catch return error.TimeOutOfRange;
        try writer.print("  <time>{s}</time>{s}", .{ &timestamp, newline });
    }
    if (waypoint.stop_s) |stop_s| {
        try writer.print("  <stopDuration>{d}</stopDuration>{s}", .{ stop_s, newline });
    }
    try writer.writeAll("</wpt>");
}

/// Writes `  <tag>text</tag>` and a newline, the text escaped. An empty text is written for
/// `name` and left out for the others: a waypoint always has a name, and an empty `<desc>`
/// says nothing.
fn text_element_write(
    writer: *std.Io.Writer,
    comptime tag: []const u8,
    text: []const u8,
    newline: []const u8,
) std.Io.Writer.Error!void {
    if (text.len == 0 and !std.mem.eql(u8, tag, "name")) return;
    try writer.writeAll("  <" ++ tag ++ ">");
    try xml_text.escape_write(writer, text);
    try writer.print("</" ++ tag ++ ">{s}", .{newline});
}

/// Returns the line ending the file uses: `\r\n` when its first line ends so, else `\n`.
fn newline_detect(bytes: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, bytes, '\n') orelse return "\n";
    if (first > 0 and bytes[first - 1] == '\r') return "\r\n";
    return "\n";
}

/// Returns `bytes` without its `<wpt>` elements, and the whitespace of the lines they were
/// alone on. The caller owns the result.
fn waypoints_remove(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (gpx.ParseError || std.mem.Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len);

    // Where the copy resumes: just past the last removed span.
    var kept_from: usize = 0;
    var position: usize = 0;
    // Bounded: each element ends past `position`.
    while (try gpx.element_next(bytes, position, "wpt")) |element| {
        assert(element.end > position);
        position = element.end;
        const span = line_span(bytes, element.start, element.end, kept_from);
        assert(span.start >= kept_from and span.end >= span.start);
        out.appendSliceAssumeCapacity(bytes[kept_from..span.start]);
        kept_from = span.end;
    }
    out.appendSliceAssumeCapacity(bytes[kept_from..]);
    assert(out.items.len <= bytes.len);
    return out.toOwnedSlice(allocator);
}

const Span = struct { start: usize, end: usize };

/// Returns what to cut for the element at `start..end`: the element, and, when it is alone on
/// its line (only blanks around it), the whole line with its newline. `floor` is where the
/// previous cut ended, which the span must not reach back past.
fn line_span(bytes: []const u8, start: usize, end: usize, floor: usize) Span {
    assert(floor <= start and start < end and end <= bytes.len);
    var span_start = start;
    while (span_start > floor and (bytes[span_start - 1] == ' ' or bytes[span_start - 1] == '\t')) {
        span_start -= 1;
    }
    var span_end = end;
    while (span_end < bytes.len and (bytes[span_end] == ' ' or bytes[span_end] == '\t')) {
        span_end += 1;
    }
    const at_line_start = span_start == 0 or bytes[span_start - 1] == '\n';
    const newline_length: usize = if (std.mem.startsWith(u8, bytes[span_end..], "\r\n"))
        2
    else if (span_end < bytes.len and bytes[span_end] == '\n')
        1
    else
        0;
    if (at_line_start and (newline_length > 0 or span_end == bytes.len)) {
        const line_end = span_end + newline_length;
        return .{ .start = span_start, .end = blank_lines_skip(bytes, line_end) };
    }
    return .{ .start = start, .end = end };
}

/// Returns `position` moved past the blank lines (only spaces and tabs) that follow, so
/// the gaps a file keeps between its waypoints go with them instead of piling up where the
/// new ones are written.
fn blank_lines_skip(bytes: []const u8, position: usize) usize {
    var line_start = position;
    // Bounded: each pass moves past one line or stops.
    while (line_start < bytes.len) {
        var cursor = line_start;
        while (cursor < bytes.len and (bytes[cursor] == ' ' or bytes[cursor] == '\t')) {
            cursor += 1;
        }
        if (std.mem.startsWith(u8, bytes[cursor..], "\r\n")) {
            line_start = cursor + 2;
        } else if (cursor < bytes.len and bytes[cursor] == '\n') {
            line_start = cursor + 1;
        } else {
            break;
        }
    }
    assert(line_start >= position and line_start <= bytes.len);
    return line_start;
}

/// Returns where the waypoints go in `bytes` (which has none): at the start of the line of
/// the first `<rte>` or `<trk>`, or just before it when other content precedes it on its
/// line, or else before `</gpx>`.
fn insertion_point(bytes: []const u8) WriteError!usize {
    const route = gpx.tag_open_find(bytes, 0, "rte");
    const track = gpx.tag_open_find(bytes, 0, "trk");
    const anchor = if (route != null and track != null)
        @min(route.?, track.?)
    else
        route orelse track orelse
            std.mem.lastIndexOf(u8, bytes, "</gpx") orelse return error.NotGpx;
    assert(anchor < bytes.len);

    const line_start = if (std.mem.lastIndexOfScalar(u8, bytes[0..anchor], '\n')) |newline|
        newline + 1
    else
        0;
    for (bytes[line_start..anchor]) |character| {
        if (character != ' ' and character != '\t') return anchor;
    }
    return line_start;
}

/// Returns how many `<wpt>` elements `bytes` has.
fn waypoints_count(bytes: []const u8) usize {
    var count: usize = 0;
    var position: usize = 0;
    // Bounded: each iteration moves `position` forward.
    while (gpx.tag_open_find(bytes, position, "wpt")) |found| {
        count += 1;
        position = found + 1;
    }
    return count;
}

fn at(text: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, text, needle).?;
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

const start_epoch_s: i64 = 1787281200; // 2026-08-21T03:00:00Z.

const start_waypoint: Waypoint = .{
    .latitude = 42.82976,
    .longitude = 0.327362,
    .elevation_m = 791,
    .name = "Vielle-Aure",
    .type_name = "Start",
    .epoch_s = start_epoch_s,
};

fn waypoint_text(allocator: std.mem.Allocator, waypoint: Waypoint, newline: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try waypoint_write(&out.writer, &waypoint, newline);
    return out.toOwnedSlice();
}

test "waypoint_write: a waypoint as the director's files have it" {
    const text = try waypoint_text(testing.allocator, start_waypoint, "\n");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\<wpt lat="42.82976" lon="0.327362">
        \\  <ele>791</ele>
        \\  <name>Vielle-Aure</name>
        \\  <type>Start</type>
        \\  <time>2026-08-21T03:00:00Z</time>
        \\</wpt>
    , text);
}

test "waypoint_write: every field, the type and time after the name" {
    var waypoint = start_waypoint;
    waypoint.description = "Soup";
    waypoint.comment = "Drop bag";
    waypoint.symbol = "Flag";
    waypoint.stop_s = 1800;
    const text = try waypoint_text(testing.allocator, waypoint, "\n");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\<wpt lat="42.82976" lon="0.327362">
        \\  <ele>791</ele>
        \\  <name>Vielle-Aure</name>
        \\  <desc>Soup</desc>
        \\  <cmt>Drop bag</cmt>
        \\  <sym>Flag</sym>
        \\  <type>Start</type>
        \\  <time>2026-08-21T03:00:00Z</time>
        \\  <stopDuration>1800</stopDuration>
        \\</wpt>
    , text);
}

test "waypoint_write: what the waypoint has not is left out" {
    const text = try waypoint_text(
        testing.allocator,
        .{ .latitude = 1, .longitude = 2, .name = "Landmark" },
        "\n",
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "<wpt lat=\"1\" lon=\"2\">\n  <name>Landmark</name>\n</wpt>",
        text,
    );
}

test "waypoint_write: a nameless waypoint keeps an empty name, empty texts are left out" {
    const text = try waypoint_text(
        testing.allocator,
        .{ .latitude = 1, .longitude = 2, .name = "", .description = "", .type_name = "" },
        "\n",
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("<wpt lat=\"1\" lon=\"2\">\n  <name></name>\n</wpt>", text);
}

test "waypoint_write: a zero elevation and a zero stop are values, not absence" {
    var waypoint = start_waypoint;
    waypoint.elevation_m = 0;
    waypoint.stop_s = 0;
    const text = try waypoint_text(testing.allocator, waypoint, "\n");
    defer testing.allocator.free(text);
    try testing.expect(has(text, "<ele>0</ele>"));
    try testing.expect(has(text, "<stopDuration>0</stopDuration>"));
}

test "waypoint_write: numbers never take an exponent, and keep their precision" {
    var waypoint = start_waypoint;
    waypoint.latitude = -0.0000005;
    waypoint.longitude = 42.909693999999995;
    waypoint.elevation_m = 1234.5;
    const text = try waypoint_text(testing.allocator, waypoint, "\n");
    defer testing.allocator.free(text);
    try testing.expect(has(text, "lat=\"-0.0000005\""));
    try testing.expect(has(text, "lon=\"42.909693999999995\""));
    try testing.expect(has(text, "<ele>1234.5</ele>"));
}

test "waypoint_write: text is escaped" {
    var waypoint = start_waypoint;
    waypoint.name = "Col d'Aubisque & <Soulor>";
    waypoint.description = "a > b";
    const text = try waypoint_text(testing.allocator, waypoint, "\n");
    defer testing.allocator.free(text);
    try testing.expect(has(text, "<name>Col d'Aubisque &amp; &lt;Soulor&gt;</name>"));
    try testing.expect(has(text, "<desc>a &gt; b</desc>"));
}

test "waypoint_write: lines end as the file's do" {
    const text = try waypoint_text(testing.allocator, start_waypoint, "\r\n");
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, text, "\r\n"));
    try testing.expectEqual(std.mem.count(u8, text, "\n"), std.mem.count(u8, text, "\r\n"));
}

test "waypoint_write: a waypoint that cannot be written is an error, not a bad file" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const base: Waypoint = .{ .latitude = 0, .longitude = 0, .name = "" };
    var cases: [10]struct { Waypoint, WriteError } = undefined;
    cases[0] = .{ with_latitude(base, 90.1), error.CoordinateInvalid };
    cases[1] = .{ with_latitude(base, -90.1), error.CoordinateInvalid };
    cases[2] = .{ with_latitude(base, nan), error.CoordinateInvalid };
    cases[3] = .{ with_longitude(base, 180.1), error.CoordinateInvalid };
    cases[4] = .{ with_longitude(base, -180.1), error.CoordinateInvalid };
    cases[5] = .{ with_longitude(base, inf), error.CoordinateInvalid };
    cases[6] = .{ with_elevation(base, nan), error.NumberInvalid };
    cases[7] = .{ with_elevation(base, -inf), error.NumberInvalid };
    cases[8] = .{ with_epoch(base, time.epoch_s_max + 1), error.TimeOutOfRange };
    cases[9] = .{ with_epoch(base, time.epoch_s_min - 1), error.TimeOutOfRange };
    for (cases) |case| {
        const result = waypoint_text(testing.allocator, case[0], "\n");
        try testing.expectError(case[1], result);
    }
}

fn with_latitude(waypoint: Waypoint, latitude: f64) Waypoint {
    var copy = waypoint;
    copy.latitude = latitude;
    return copy;
}

fn with_longitude(waypoint: Waypoint, longitude: f64) Waypoint {
    var copy = waypoint;
    copy.longitude = longitude;
    return copy;
}

fn with_elevation(waypoint: Waypoint, elevation_m: f64) Waypoint {
    var copy = waypoint;
    copy.elevation_m = elevation_m;
    return copy;
}

fn with_epoch(waypoint: Waypoint, epoch_s: i64) Waypoint {
    var copy = waypoint;
    copy.epoch_s = epoch_s;
    return copy;
}

test "waypoint_write: the edges of what can be written are written" {
    for ([_]Waypoint{
        .{ .latitude = 90, .longitude = 180, .name = "NE", .epoch_s = time.epoch_s_max },
        .{ .latitude = -90, .longitude = -180, .name = "SW", .epoch_s = time.epoch_s_min },
    }) |waypoint| {
        const text = try waypoint_text(testing.allocator, waypoint, "\n");
        testing.allocator.free(text);
    }
}

/// A director's file: metadata, two waypoints (one self-closing), a track with an extension.
const director_file =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<gpx version="1.1" creator="Majuschule" xmlns="http://www.topografix.com/GPX/1/1">
    \\<metadata>
    \\  <name>GRP 2026</name>
    \\</metadata>
    \\<wpt lat="42.82976" lon="0.327362">
    \\  <ele>791</ele>
    \\  <name>Old start</name>
    \\</wpt>
    \\
    \\<wpt lat="42.9" lon="0.1"/>
    \\<trk>
    \\  <name>Trace</name>
    \\  <trkseg><trkpt lat="42.82976" lon="0.327362"><ele>791</ele>
    \\  <extensions><x:node/></extensions></trkpt></trkseg>
    \\</trk>
    \\</gpx>
    \\
;

const new_waypoints = [_]Waypoint{
    start_waypoint,
    .{ .latitude = 42.9, .longitude = 0.1, .name = "La Mongie", .type_name = "TimeBarrier" },
};

test "waypoints_replace: the waypoints change and the rest stays byte for byte" {
    const out = try waypoints_replace(testing.allocator, director_file, &new_waypoints);
    defer testing.allocator.free(out);

    try testing.expect(!has(out, "Old start"));
    try testing.expect(!has(out, "lat=\"42.9\" lon=\"0.1\"/>"));
    try testing.expect(has(out, "<name>La Mongie</name>"));

    // Everything before the first old waypoint and from the track on is the original's.
    const head_length = at(director_file, "<wpt");
    const tail_start = at(director_file, "<trk>");
    try testing.expectEqualStrings(director_file[0..head_length], out[0..head_length]);
    try testing.expect(std.mem.endsWith(u8, out, director_file[tail_start..]));
    // The only thing between them is the new waypoints.
    const tail_length = director_file.len - tail_start;
    const between = out[head_length .. out.len - tail_length];
    try testing.expectEqual(@as(usize, 2), waypoints_count(between));
}

test "waypoints_replace: the waypoints go after the metadata and before the track" {
    const out = try waypoints_replace(testing.allocator, director_file, &new_waypoints);
    defer testing.allocator.free(out);
    const metadata_end = at(out, "</metadata>");
    const first = at(out, "<wpt");
    const last = std.mem.lastIndexOf(u8, out, "</wpt>").?;
    const track = at(out, "<trk>");
    try testing.expect(metadata_end < first and last < track);
}

test "waypoints_replace: the order given is the order written" {
    const out = try waypoints_replace(testing.allocator, director_file, &new_waypoints);
    defer testing.allocator.free(out);
    try testing.expect(at(out, "Vielle-Aure") < at(out, "La Mongie"));
}

test "waypoints_replace: replacing again changes nothing" {
    const once = try waypoints_replace(testing.allocator, director_file, &new_waypoints);
    defer testing.allocator.free(once);
    const twice = try waypoints_replace(testing.allocator, once, &new_waypoints);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "waypoints_replace: a file without waypoints gets them before its track" {
    const bare = "<gpx version=\"1.1\">\n<trk><trkseg></trkseg></trk>\n</gpx>\n";
    const out = try waypoints_replace(testing.allocator, bare, &new_waypoints);
    defer testing.allocator.free(out);
    try testing.expect(at(out, "<wpt") < at(out, "<trk>"));
    try testing.expect(std.mem.endsWith(u8, out, "<trk><trkseg></trkseg></trk>\n</gpx>\n"));
}

test "waypoints_replace: waypoints go before a route too" {
    const route = "<gpx version=\"1.1\"><metadata/><rte><rtept lat=\"1\" lon=\"1\"/></rte></gpx>";
    const out = try waypoints_replace(testing.allocator, route, &new_waypoints);
    defer testing.allocator.free(out);
    try testing.expect(at(out, "<wpt") < at(out, "<rte>"));
    try testing.expect(at(out, "<metadata/>") < at(out, "<wpt"));
}

test "waypoints_replace: a stray <trkpt> is not a track" {
    const odd = "<gpx version=\"1.1\"><metadata/><trkpt lat=\"1\" lon=\"1\"/></gpx>";
    const out = try waypoints_replace(testing.allocator, odd, &new_waypoints);
    defer testing.allocator.free(out);
    // No <trk>: before </gpx>, after the stray point.
    try testing.expect(at(out, "<trkpt") < at(out, "<wpt"));
    try testing.expect(std.mem.endsWith(u8, out, "</gpx>"));
}

test "waypoints_replace: waypoints written after the track move before it" {
    const late = "<gpx version=\"1.1\"><trk></trk>\n" ++
        "<wpt lat=\"1\" lon=\"1\"><name>x</name></wpt>\n</gpx>";
    const out = try waypoints_replace(testing.allocator, late, &new_waypoints);
    defer testing.allocator.free(out);
    try testing.expect(!has(out, "<name>x</name>"));
    try testing.expect(at(out, "<wpt") < at(out, "<trk>"));
    try testing.expectEqual(@as(usize, 2), waypoints_count(out));
}

test "waypoints_replace: an element that only starts like a waypoint is kept" {
    const text = "<gpx version=\"1.1\"><wptx>keep</wptx><trk></trk></gpx>";
    const out = try waypoints_replace(testing.allocator, text, &.{});
    defer testing.allocator.free(out);
    try testing.expect(has(out, "<wptx>keep</wptx>"));
}

test "waypoints_replace: a file with Windows line endings keeps them" {
    const crlf = try std.mem.replaceOwned(u8, testing.allocator, director_file, "\n", "\r\n");
    defer testing.allocator.free(crlf);
    const out = try waypoints_replace(testing.allocator, crlf, &new_waypoints);
    defer testing.allocator.free(out);
    try testing.expectEqual(std.mem.count(u8, out, "\n"), std.mem.count(u8, out, "\r\n"));
}

test "waypoints_replace: no waypoints is a file without any" {
    const out = try waypoints_replace(testing.allocator, director_file, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), waypoints_count(out));
    try testing.expect(has(out, "<trk>"));
}

test "waypoints_replace: blanks around a waypoint are cut with it, other content is not" {
    const text = "<gpx>\n  <wpt lat=\"1\" lon=\"1\"/>  \n" ++
        "<metadata/> <wpt lat=\"2\" lon=\"2\"/> <b/>\n<trk/></gpx>";
    const out = try waypoints_replace(testing.allocator, text, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<gpx>\n<metadata/>  <b/>\n<trk/></gpx>", out);
}

test "waypoints_replace: the gaps between removed waypoints go with them" {
    const text = "<gpx>\n<wpt lat=\"1\" lon=\"1\"/>\n\n  \n<wpt lat=\"2\" lon=\"2\"/>\r\n\r\n" ++
        "<trk/>\n\n</gpx>";
    const out = try waypoints_replace(testing.allocator, text, &.{});
    defer testing.allocator.free(out);
    // Blank lines after the last waypoint go too; those before the track's content stay.
    try testing.expectEqualStrings("<gpx>\n<trk/>\n\n</gpx>", out);
}

test "waypoints_replace: text that is not a GPX file is rejected" {
    try testing.expectError(error.NotGpx, waypoints_replace(testing.allocator, "hello", &.{}));
    try testing.expectError(error.NotGpx, waypoints_replace(testing.allocator, "", &.{}));
    const unclosed = waypoints_replace(testing.allocator, "<gpx><trk/>", &.{});
    try testing.expectError(error.NotGpx, unclosed);
}

test "waypoints_replace: a malformed waypoint in the file is rejected, not skipped" {
    const text = "<gpx><wpt lat=\"1\" lon=\"1\"><name>x</name><trk/></gpx>";
    const result = waypoints_replace(testing.allocator, text, &.{});
    try testing.expectError(error.ElementUnclosed, result);
}

test "waypoints_replace: a waypoint that cannot be written leaves nothing half made" {
    const bad = [_]Waypoint{ start_waypoint, .{ .latitude = 91, .longitude = 0, .name = "bad" } };
    try testing.expectError(
        error.CoordinateInvalid,
        waypoints_replace(testing.allocator, director_file, &bad),
    );
}

test "waypoints_replace: parse reads back what was written" {
    const waypoints = [_]Waypoint{
        .{
            .latitude = 42.82976,
            .longitude = 0.327362,
            .elevation_m = 791,
            .name = "Col d'Aubisque & <Soulor> (retour)",
            .description = "Soup & bread",
            .comment = "Drop bag",
            .symbol = "Flag",
            .type_name = "LifeBase",
            .epoch_s = start_epoch_s,
            .stop_s = 1800,
        },
        .{ .latitude = -0.0000005, .longitude = 42.909693999999995, .name = "" },
    };
    const out = try waypoints_replace(testing.allocator, director_file, &waypoints);
    defer testing.allocator.free(out);

    const read = try gpx.waypoints_read(testing.allocator, out);
    defer gpx.waypoints_free(testing.allocator, read);
    try testing.expectEqual(waypoints.len, read.len);
    for (waypoints, read) |expected, actual| {
        try testing.expectEqual(expected.latitude, actual.latitude);
        try testing.expectEqual(expected.longitude, actual.longitude);
        try testing.expectEqual(expected.elevation_m, actual.elevation_m);
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqual(expected.epoch_s, actual.epoch_s);
        try testing.expectEqual(expected.stop_s, actual.stop_s);
        try testing.expectEqualDeep(expected.description, actual.description);
        try testing.expectEqualDeep(expected.comment, actual.comment);
        try testing.expectEqualDeep(expected.symbol, actual.symbol);
        try testing.expectEqualDeep(expected.type_name, actual.type_name);
    }
}

test "waypoints_replace: waypoints read from a file, written, and read again are the same" {
    const first = try gpx.waypoints_read(testing.allocator, director_file);
    defer gpx.waypoints_free(testing.allocator, first);
    const out = try waypoints_replace(testing.allocator, director_file, first);
    defer testing.allocator.free(out);
    const second = try gpx.waypoints_read(testing.allocator, out);
    defer gpx.waypoints_free(testing.allocator, second);

    try testing.expectEqual(first.len, second.len);
    for (first, second) |before, after| {
        try testing.expectEqual(before.latitude, after.latitude);
        try testing.expectEqualStrings(before.name, after.name);
    }
}
