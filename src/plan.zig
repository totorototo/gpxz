//! `plan.json`: a race strategy for one course, as a standalone document. The course (an
//! extended GPX) holds the facts: checkpoints, cutoffs, aid stations. The plan holds what the
//! runner intends to do there: the pace model's inputs and the arrival and stop at each
//! checkpoint. A course can have several plans, and each plan names its course by the SHA-256
//! of the GPX bytes, so a plan made for another file, or for an edited one, is detectable.

const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const PlanEntry = @import("calibration.zig").PlanEntry;
const pace_model = @import("pace_model.zig");

/// Bumped on any change a v1 reader can't read: a renamed, removed or retyped field.
pub const schema_version: u32 = 1;

/// The SHA-256 of a course's GPX bytes, as lowercase hex.
pub const Sha256Hex = [Sha256.digest_length * 2]u8;

pub const Plan = struct {
    schema_version: u32,
    course: Course,
    model: Model,
    /// One per checkpoint, in race order; borrowed from `GPXData.plan`, not owned.
    entries: []const PlanEntry,
};

/// Which course the plan is for. `name` and `distance_m` are for a human reading the file;
/// `sha256` is what a reader compares.
pub const Course = struct {
    name: ?[]const u8,
    sha256: Sha256Hex,
    distance_m: f64,
};

/// The pace model's inputs that produced the entries. Weather is not part of v1, so a plan
/// built with a weather lookup is refused rather than written with inputs it can't replay.
pub const Model = struct {
    pace_base_s_per_km: f64,
    fatigue_coefficient: f64,
    life_base_stop_s: u32,
};

pub fn course_sha256(bytes: []const u8) Sha256Hex {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    assert(hex.len == 64);
    return hex;
}

/// Returns the plan for the course in `bytes`, from the entries `parse` computed on those same
/// bytes with `settings`. Borrows `name` and `entries`, so they must outlive the plan.
pub fn plan_build(
    bytes: []const u8,
    name: ?[]const u8,
    distance_m: f64,
    entries: []const PlanEntry,
    settings: *const pace_model.Settings,
) Plan {
    settings.assert_valid();
    // v1 has no weather field: writing a plan whose times depend on one would lose an input.
    assert(settings.weather.names.len == 0);
    assert(distance_m >= 0 and std.math.isFinite(distance_m));
    const plan: Plan = .{
        .schema_version = schema_version,
        .course = .{ .name = name, .sha256 = course_sha256(bytes), .distance_m = distance_m },
        .model = .{
            .pace_base_s_per_km = settings.pace_base_s_per_km,
            .fatigue_coefficient = settings.fatigue_coefficient,
            .life_base_stop_s = settings.life_base_stop_s,
        },
        .entries = entries,
    };
    assert(plan.entries.len == entries.len);
    // Paired with `plan_read`: a plan gpxz writes is always one it reads back.
    assert(plan_valid(&plan));
    return plan;
}

/// Whether `plan` holds the invariants `calibration.plan_compute` guarantees. The builder
/// asserts it and the reader returns `error.PlanInvalid` without it, so the two agree on what a
/// valid plan is.
pub fn plan_valid(plan: *const Plan) bool {
    if (plan.schema_version != schema_version) return false;
    if (!sha256_hex_valid(&plan.course.sha256)) return false;
    if (!(plan.course.distance_m >= 0) or !std.math.isFinite(plan.course.distance_m)) return false;
    const model = &plan.model;
    if (!(model.pace_base_s_per_km > 0) or !std.math.isFinite(model.pace_base_s_per_km)) {
        return false;
    }
    if (!(model.fatigue_coefficient >= 0) or !std.math.isFinite(model.fatigue_coefficient)) {
        return false;
    }
    return entries_valid(plan.entries, plan.course.distance_m);
}

/// Lowercase only, as `course_sha256` writes it, so comparing two hashes is a byte compare.
fn sha256_hex_valid(hex: *const Sha256Hex) bool {
    for (hex) |character| {
        const digit = character >= '0' and character <= '9';
        const letter = character >= 'a' and character <= 'f';
        if (!digit and !letter) return false;
    }
    return true;
}

/// Entries run in race order from the first checkpoint: every cumulative value counts up from 0
/// and never passes the course, and each arrival comes after the previous departure.
fn entries_valid(entries: []const PlanEntry, distance_m_course: f64) bool {
    if (entries.len == 0) return true;
    if (entries[0].distance_m != 0 or entries[0].duration_s_arrival != 0) return false;
    var previous = entries[0];
    for (entries, 0..) |*entry, number| {
        if (!entry_valid(entry, distance_m_course)) return false;
        if (number == 0) continue;
        if (entry.index < previous.index) return false;
        if (entry.distance_m < previous.distance_m) return false;
        if (entry.elevation_gain_m < previous.elevation_gain_m) return false;
        if (entry.elevation_loss_m < previous.elevation_loss_m) return false;
        if (entry.duration_s_arrival < previous.duration_s_departure) return false;
        previous = entry.*;
    }
    return true;
}

/// One entry on its own: finite numbers, coordinates on the globe, no negative stop, and a
/// departure that is exactly arrival plus stop. Exact, because JSON f64 round-trips exactly
/// and an editor that changes one of the three must recompute the third.
fn entry_valid(entry: *const PlanEntry, distance_m_course: f64) bool {
    const values = [_]f64{
        entry.latitude,           entry.longitude,        entry.elevation_m,
        entry.distance_m,         entry.elevation_gain_m, entry.elevation_loss_m,
        entry.duration_s_arrival, entry.stop_s,           entry.duration_s_departure,
        entry.margin_s orelse 0,
    };
    for (values) |value| if (!std.math.isFinite(value)) return false;
    if (@abs(entry.latitude) > 90 or @abs(entry.longitude) > 180) return false;
    if (entry.distance_m < 0 or entry.distance_m > distance_m_course) return false;
    if (entry.elevation_gain_m < 0 or entry.elevation_loss_m < 0) return false;
    if (entry.stop_s < 0) return false;
    return entry.duration_s_departure == entry.duration_s_arrival + entry.stop_s;
}

/// A plan is a few KiB per hundred checkpoints; this bounds what a reader allocates for one.
pub const plan_bytes_max = 4 * 1024 * 1024;

pub const ReadError = std.json.ParseError(std.json.Scanner) || error{
    PlanTooLarge,
    SchemaVersionUnsupported,
    PlanInvalid,
};

/// Parses and validates `plan.json` bytes. The result owns every string and the entries (it
/// copies them out of `bytes`), and the caller frees it with `deinit`. Checking the course is
/// separate (`course_matches`), since a reader may want to show a plan for a missing course.
pub fn plan_read(allocator: std.mem.Allocator, bytes: []const u8) ReadError!std.json.Parsed(Plan) {
    if (bytes.len > plan_bytes_max) return error.PlanTooLarge;
    // The version first, ignoring the rest, so a v2 file is "unsupported" rather than whatever
    // v1's strict parse would trip on.
    const Version = struct { schema_version: u32 };
    const version = try std.json.parseFromSlice(Version, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    const version_number = version.value.schema_version;
    version.deinit();
    if (version_number != schema_version) return error.SchemaVersionUnsupported;

    const parsed = try std.json.parseFromSlice(Plan, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    if (!plan_valid(&parsed.value)) return error.PlanInvalid;
    assert(parsed.value.schema_version == schema_version);
    return parsed;
}

/// Whether `plan` was made for the course in `bytes`: the exact bytes, so any edit to the GPX,
/// even one that leaves the route unchanged, makes the plan stale.
pub fn course_matches(plan: *const Plan, bytes: []const u8) bool {
    assert(sha256_hex_valid(&plan.course.sha256));
    const hex = course_sha256(bytes);
    assert(sha256_hex_valid(&hex));
    return std.mem.eql(u8, &hex, &plan.course.sha256);
}

/// Writes `plan` as `plan.json`: indented JSON with a trailing newline.
pub fn plan_write(writer: *std.Io.Writer, plan: *const Plan) std.Io.Writer.Error!void {
    assert(plan_valid(plan));
    const options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };
    try std.json.Stringify.value(plan.*, options, writer);
    try writer.writeByte('\n');
}

const testing = std.testing;

fn entry_test(name: []const u8, distance_m: f64, arrival_s: f64, stop_s: f64) PlanEntry {
    return .{
        .name = name,
        .type_name = null,
        .index = 0,
        .latitude = 45.0,
        .longitude = 6.0,
        .elevation_m = 1000.0,
        .distance_m = distance_m,
        .elevation_gain_m = 0,
        .elevation_loss_m = 0,
        .duration_s_arrival = arrival_s,
        .stop_s = stop_s,
        .duration_s_departure = arrival_s + stop_s,
        .epoch_s_arrival = null,
        .epoch_s_cutoff = null,
        .margin_s = null,
    };
}

test "course_sha256: known digests, and one byte changes it" {
    // The SHA-256 test vectors from FIPS 180-2.
    const empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try testing.expectEqualStrings(empty, &course_sha256(""));
    try testing.expectEqualStrings(abc, &course_sha256("abc"));
    try testing.expect(!std.mem.eql(u8, &course_sha256("abc"), &course_sha256("abd")));
}

test "plan_build: copies the model and hashes the bytes" {
    const entries = [_]PlanEntry{
        entry_test("Start", 0, 0, 0),
        entry_test("LB1", 30_000, 4 * 3600, 1800),
        entry_test("Finish", 60_000, 9 * 3600, 0),
    };
    const settings: pace_model.Settings = .{ .pace_base_s_per_km = 420, .life_base_stop_s = 1800 };
    const plan = plan_build("<gpx/>", "Loop", 60_000, &entries, &settings);
    try testing.expectEqual(schema_version, plan.schema_version);
    try testing.expectEqualStrings("Loop", plan.course.name.?);
    try testing.expectEqualStrings(&course_sha256("<gpx/>"), &plan.course.sha256);
    try testing.expectEqual(@as(f64, 420), plan.model.pace_base_s_per_km);
    try testing.expectEqual(settings.fatigue_coefficient, plan.model.fatigue_coefficient);
    try testing.expectEqual(@as(u32, 1800), plan.model.life_base_stop_s);
    try testing.expectEqual(@as(usize, 3), plan.entries.len);
}

test "plan_build: zero entries and an unnamed course" {
    const plan = plan_build("", null, 0, &.{}, &.{});
    try testing.expect(plan.course.name == null);
    try testing.expectEqual(@as(usize, 0), plan.entries.len);
}

test "plan_write: the JSON has every v1 key, and entries keep their order" {
    const entries = [_]PlanEntry{
        entry_test("Start", 0, 0, 0),
        entry_test("Finish", 10_000, 3600, 0),
    };
    const plan = plan_build("<gpx/>", "Loop", 10_000, &entries, &.{});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try plan_write(&out.writer, &plan);
    try testing.expect(std.mem.endsWith(u8, out.written(), "}\n"));

    const json = out.written();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, schema_version), root.get("schema_version").?.integer);
    const course = root.get("course").?.object;
    try testing.expectEqualStrings("Loop", course.get("name").?.string);
    try testing.expectEqualStrings(&plan.course.sha256, course.get("sha256").?.string);
    try testing.expect(root.get("model").?.object.get("pace_base_s_per_km") != null);
    const items = root.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Start", items[0].object.get("name").?.string);
    try testing.expectEqualStrings("Finish", items[1].object.get("name").?.string);
    // Unnamed course: the key stays, as null, so a reader never has to guess v1's shape.
    const unnamed = plan_build("", null, 0, &.{}, &.{});
    out.clearRetainingCapacity();
    try plan_write(&out.writer, &unnamed);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"name\": null") != null);
}

test "plan_write: round-trips through std.json into Plan" {
    const entries = [_]PlanEntry{ entry_test("Start", 0, 0, 0), entry_test("End", 5000, 1800, 0) };
    const plan = plan_build("bytes", "Out and back", 5000, &entries, &.{});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try plan_write(&out.writer, &plan);
    const parsed = try std.json.parseFromSlice(Plan, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(&plan.course.sha256, &parsed.value.course.sha256);
    try testing.expectEqual(plan.model, parsed.value.model);
    try testing.expectEqual(@as(f64, 1800), parsed.value.entries[1].duration_s_arrival);
}

/// A valid two-entry plan for the reader tests to break one field at a time.
fn plan_test(entries: *[2]PlanEntry) Plan {
    entries.* = .{ entry_test("Start", 0, 0, 0), entry_test("End", 5000, 1800, 600) };
    return plan_build("<gpx/>", "Loop", 5000, entries, &.{});
}

/// Serializes without `plan_write`'s assert, so a test can write a plan gpxz never would.
fn json_test(plan: *const Plan) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(plan.*, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "plan_read: reads what plan_write wrote, and owns it" {
    var entries: [2]PlanEntry = undefined;
    const plan = plan_test(&entries);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try plan_write(&out.writer, &plan);
    const bytes = try testing.allocator.dupe(u8, out.written());

    const parsed = try plan_read(testing.allocator, bytes);
    defer parsed.deinit();
    // The input is gone; the strings must not point into it.
    @memset(bytes, 0);
    testing.allocator.free(bytes);
    try testing.expectEqualStrings("Loop", parsed.value.course.name.?);
    try testing.expectEqualStrings("End", parsed.value.entries[1].name);
    try testing.expectEqual(plan.model, parsed.value.model);
    try testing.expectEqual(@as(f64, 2400), parsed.value.entries[1].duration_s_departure);
}

test "plan_read: zero entries and a null name are valid" {
    const plan = plan_build("", null, 0, &.{}, &.{});
    const bytes = try json_test(&plan);
    defer testing.allocator.free(bytes);
    const parsed = try plan_read(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expect(parsed.value.course.name == null);
    try testing.expectEqual(@as(usize, 0), parsed.value.entries.len);
}

test "plan_read: other schema versions, missing version, not JSON, unknown v1 field" {
    const allocator = testing.allocator;
    // A v2 file with fields v1 doesn't know: unsupported, not a v1 parse error.
    const v2 = "{\"schema_version\": 2, \"segments\": [], \"course\": 7}";
    try testing.expectError(error.SchemaVersionUnsupported, plan_read(allocator, v2));
    const v0 = "{\"schema_version\": 0}";
    try testing.expectError(error.SchemaVersionUnsupported, plan_read(allocator, v0));
    try testing.expectError(error.MissingField, plan_read(allocator, "{\"course\": {}}"));
    try testing.expectError(error.SyntaxError, plan_read(allocator, "not json"));
    try testing.expectError(error.UnexpectedEndOfInput, plan_read(allocator, ""));
    const negative = "{\"schema_version\": -1}";
    try testing.expectError(error.Overflow, plan_read(allocator, negative));

    var entries: [2]PlanEntry = undefined;
    const plan = plan_test(&entries);
    const bytes = try json_test(&plan);
    defer allocator.free(bytes);
    const extra = try std.mem.concat(allocator, u8, &.{ bytes[0 .. bytes.len - 1], ",\"x\":1}" });
    defer allocator.free(extra);
    try testing.expectError(error.UnknownField, plan_read(allocator, extra));
}

test "plan_read: plan_bytes_max is accepted, one byte more is not" {
    const allocator = testing.allocator;
    var entries: [2]PlanEntry = undefined;
    const plan = plan_test(&entries);
    const bytes = try json_test(&plan);
    defer allocator.free(bytes);
    // Trailing whitespace pads a valid plan to an exact length.
    const padded = try allocator.alloc(u8, plan_bytes_max + 1);
    defer allocator.free(padded);
    @memset(padded, ' ');
    @memcpy(padded[0..bytes.len], bytes);
    const parsed = try plan_read(allocator, padded[0..plan_bytes_max]);
    parsed.deinit();
    try testing.expectError(error.PlanTooLarge, plan_read(allocator, padded));
}

test "plan_read: each broken invariant is PlanInvalid" {
    const Break = enum {
        departure,
        stop_negative,
        arrival_early,
        distance_past_course,
        distance_backwards,
        first_not_zero,
        latitude,
        sha256_uppercase,
        sha256_not_hex,
        pace_zero,
        fatigue_negative,
    };
    for (std.enums.values(Break)) |which| {
        var entries: [2]PlanEntry = undefined;
        var plan = plan_test(&entries);
        switch (which) {
            .departure => entries[1].duration_s_departure += 1,
            .stop_negative => {
                entries[1].stop_s = -1;
                entries[1].duration_s_departure = entries[1].duration_s_arrival - 1;
            },
            .arrival_early => entries[0].duration_s_departure = 3600,
            .distance_past_course => entries[1].distance_m = 5001,
            .distance_backwards => entries[1].distance_m = -1,
            .first_not_zero => entries[0].distance_m = 1,
            .latitude => entries[1].latitude = 90.5,
            .sha256_uppercase => plan.course.sha256[0] = 'A',
            .sha256_not_hex => plan.course.sha256[63] = 'g',
            .pace_zero => plan.model.pace_base_s_per_km = 0,
            .fatigue_negative => plan.model.fatigue_coefficient = -0.001,
        }
        try testing.expect(!plan_valid(&plan));
        const bytes = try json_test(&plan);
        defer testing.allocator.free(bytes);
        try testing.expectError(error.PlanInvalid, plan_read(testing.allocator, bytes));
    }
}

test "plan_read: a non-finite number is PlanInvalid, a short hash a parse error" {
    const allocator = testing.allocator;
    var entries: [2]PlanEntry = undefined;
    const plan = plan_test(&entries);
    const bytes = try json_test(&plan);
    defer allocator.free(bytes);
    // std.json reads a float from a string, so "nan" reaches the validator as a NaN.
    const stop_s = "\"stop_s\":600";
    const nan = try std.mem.replaceOwned(u8, allocator, bytes, stop_s, "\"stop_s\":\"nan\"");
    defer allocator.free(nan);
    try testing.expect(!std.mem.eql(u8, nan, bytes));
    try testing.expectError(error.PlanInvalid, plan_read(allocator, nan));

    const short = try std.mem.replaceOwned(u8, allocator, bytes, &plan.course.sha256, "abc");
    defer allocator.free(short);
    try testing.expectError(error.LengthMismatch, plan_read(allocator, short));
}

test "course_matches: the same bytes match, one changed byte does not" {
    var entries: [2]PlanEntry = undefined;
    const plan = plan_test(&entries);
    try testing.expect(course_matches(&plan, "<gpx/>"));
    try testing.expect(!course_matches(&plan, "<gpx />"));
    try testing.expect(!course_matches(&plan, ""));
}
