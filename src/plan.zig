//! `plan.json`: a race strategy for one course, as a standalone document. The course (an
//! extended GPX) holds the facts: checkpoints, cutoffs, aid stations. The plan holds what the
//! runner intends to do there: the pace model's inputs and the arrival and stop at each
//! checkpoint. A course can have several plans, and each plan names its course by the SHA-256
//! of the GPX bytes, so a plan made for another file, or for an edited one, is detectable.
//!
//! v2 adds fueling (`fueling.zig`): the runner's hourly targets and refill points in
//! `model.fueling`, and what to leave each checkpoint with in `carry`, one per entry. A v1
//! file still reads, with no fueling.

const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const PlanEntry = @import("calibration.zig").PlanEntry;
const fueling = @import("fueling.zig");
const pace_model = @import("pace_model.zig");

/// The version gpxz writes. Bumped on any change an older reader can't read: an added,
/// renamed, removed or retyped field (the reader rejects unknown fields).
pub const schema_version: u32 = 2;
/// The oldest version gpxz still reads. v1 is v2 without fueling, so it parses into v2's
/// types through their defaults.
pub const schema_version_read_min: u32 = 1;

/// The SHA-256 of a course's GPX bytes, as lowercase hex.
pub const Sha256Hex = [Sha256.digest_length * 2]u8;

pub const Plan = struct {
    schema_version: u32,
    course: Course,
    model: Model,
    /// One per checkpoint, in race order; borrowed from `GPXData.plan`, not owned.
    entries: []const PlanEntry,
    /// What to leave each entry with: one per entry with `model.fueling`, else empty.
    /// Kept apart from `entries` so they keep v1's shape and the pace model's types.
    carry: []const ?fueling.Carry = &.{},
};

/// Which course the plan is for. `name` and `distance_m` are for a human reading the file;
/// `sha256` is what a reader compares.
pub const Course = struct {
    name: ?[]const u8,
    sha256: Sha256Hex,
    distance_m: f64,
};

/// The inputs that produced the entries and the carry. Weather is not part of the schema, so
/// a plan built with a weather lookup is refused rather than written with inputs it can't
/// replay.
pub const Model = struct {
    pace_base_s_per_km: f64,
    fatigue_coefficient: f64,
    life_base_stop_s: u32,
    /// Null when the runner plans no fueling, and always in a v1 file.
    fueling: ?fueling.Fueling = null,
};

pub fn course_sha256(bytes: []const u8) Sha256Hex {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    assert(hex.len == 64);
    return hex;
}

/// Returns the plan for the course in `bytes`, from the entries `parse` computed on those same
/// bytes with `settings`, and the fueling `carry_compute` computed on those entries, if any.
/// Borrows `name`, `entries` and the fueling's slices, so they must outlive the plan.
pub fn plan_build(
    bytes: []const u8,
    name: ?[]const u8,
    distance_m: f64,
    entries: []const PlanEntry,
    settings: *const pace_model.Settings,
    fuel_plan: ?*const fueling.FuelPlan,
) Plan {
    settings.assert_valid();
    // The schema has no weather field: writing a plan whose times depend on one would lose an
    // input.
    assert(settings.weather.names.len == 0);
    assert(distance_m >= 0 and std.math.isFinite(distance_m));
    if (fuel_plan) |fuel| assert(fuel.carry.len == entries.len);
    const plan: Plan = .{
        .schema_version = schema_version,
        .course = .{ .name = name, .sha256 = course_sha256(bytes), .distance_m = distance_m },
        .model = .{
            .pace_base_s_per_km = settings.pace_base_s_per_km,
            .fatigue_coefficient = settings.fatigue_coefficient,
            .life_base_stop_s = settings.life_base_stop_s,
            .fueling = if (fuel_plan) |fuel| fuel.fueling else null,
        },
        .entries = entries,
        .carry = if (fuel_plan) |fuel| fuel.carry else &.{},
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
    if (plan.schema_version < schema_version_read_min) return false;
    if (plan.schema_version > schema_version) return false;
    if (!sha256_hex_valid(&plan.course.sha256)) return false;
    if (!(plan.course.distance_m >= 0) or !std.math.isFinite(plan.course.distance_m)) return false;
    // The model is the runner's settings: the same ranges as any other input.
    const settings: pace_model.Settings = .{
        .pace_base_s_per_km = plan.model.pace_base_s_per_km,
        .fatigue_coefficient = plan.model.fatigue_coefficient,
        .life_base_stop_s = plan.model.life_base_stop_s,
    };
    settings.validate() catch return false;
    if (!entries_valid(plan.entries, plan.course.distance_m)) return false;
    return fuel_valid(plan);
}

/// Fueling: none in a v1 file; else no carry without fueling, and with it, valid targets and
/// exactly the carry `carry_compute` gives. After `entries_valid`, which `carry_matches`
/// relies on to see times that run forward.
fn fuel_valid(plan: *const Plan) bool {
    const fuel = plan.model.fueling orelse return plan.carry.len == 0;
    if (plan.schema_version < 2) return false;
    if (!fueling.fueling_valid(&fuel, plan.entries.len)) return false;
    return fueling.carry_matches(plan.entries, &fuel, plan.carry);
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
    // The version first, ignoring the rest, so a newer file is "unsupported" rather than
    // whatever this version's strict parse would trip on.
    const Version = struct { schema_version: u32 };
    const version = try std.json.parseFromSlice(Version, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    const version_number = version.value.schema_version;
    version.deinit();
    if (version_number < schema_version_read_min) return error.SchemaVersionUnsupported;
    if (version_number > schema_version) return error.SchemaVersionUnsupported;

    const parsed = try std.json.parseFromSlice(Plan, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    if (!plan_valid(&parsed.value)) return error.PlanInvalid;
    assert(parsed.value.schema_version >= schema_version_read_min);
    assert(parsed.value.schema_version <= schema_version);
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
    // gpxz writes the current version only: a plan read from an older file is rebuilt first.
    assert(plan.schema_version == schema_version);
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
    const plan = plan_build("<gpx/>", "Loop", 60_000, &entries, &settings, null);
    try testing.expectEqual(schema_version, plan.schema_version);
    try testing.expectEqualStrings("Loop", plan.course.name.?);
    try testing.expectEqualStrings(&course_sha256("<gpx/>"), &plan.course.sha256);
    try testing.expectEqual(@as(f64, 420), plan.model.pace_base_s_per_km);
    try testing.expectEqual(settings.fatigue_coefficient, plan.model.fatigue_coefficient);
    try testing.expectEqual(@as(u32, 1800), plan.model.life_base_stop_s);
    try testing.expectEqual(@as(usize, 3), plan.entries.len);
}

test "plan_build: zero entries and an unnamed course" {
    const plan = plan_build("", null, 0, &.{}, &.{}, null);
    try testing.expect(plan.course.name == null);
    try testing.expectEqual(@as(usize, 0), plan.entries.len);
}

test "plan_write: the JSON has every v2 key, and entries keep their order" {
    const entries = [_]PlanEntry{
        entry_test("Start", 0, 0, 0),
        entry_test("Finish", 10_000, 3600, 0),
    };
    const plan = plan_build("<gpx/>", "Loop", 10_000, &entries, &.{}, null);
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
    const model = root.get("model").?.object;
    try testing.expect(model.get("pace_base_s_per_km") != null);
    // No fueling: the keys stay, as null and [], so a reader never has to guess v2's shape.
    try testing.expect(model.get("fueling").? == .null);
    try testing.expectEqual(@as(usize, 0), root.get("carry").?.array.items.len);
    const items = root.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Start", items[0].object.get("name").?.string);
    try testing.expectEqualStrings("Finish", items[1].object.get("name").?.string);
    // Unnamed course: the key stays, as null.
    const unnamed = plan_build("", null, 0, &.{}, &.{}, null);
    out.clearRetainingCapacity();
    try plan_write(&out.writer, &unnamed);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"name\": null") != null);
}

test "plan_write: round-trips through std.json into Plan" {
    const entries = [_]PlanEntry{ entry_test("Start", 0, 0, 0), entry_test("End", 5000, 1800, 0) };
    const plan = plan_build("bytes", "Out and back", 5000, &entries, &.{}, null);
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
    return plan_build("<gpx/>", "Loop", 5000, entries, &.{}, null);
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
    const plan = plan_build("", null, 0, &.{}, &.{}, null);
    const bytes = try json_test(&plan);
    defer testing.allocator.free(bytes);
    const parsed = try plan_read(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expect(parsed.value.course.name == null);
    try testing.expectEqual(@as(usize, 0), parsed.value.entries.len);
}

test "plan_read: other schema versions, missing version, not JSON, unknown field" {
    const allocator = testing.allocator;
    // A v3 file with fields v2 doesn't know: unsupported, not a v2 parse error.
    const v3 = "{\"schema_version\": 3, \"segments\": [], \"course\": 7}";
    try testing.expectError(error.SchemaVersionUnsupported, plan_read(allocator, v3));
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
        pace_over_max,
        fatigue_negative,
        fatigue_over_max,
        stop_over_max,
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
            .pace_over_max => plan.model.pace_base_s_per_km = pace_model.pace_base_s_per_km_max + 1,
            .fatigue_negative => plan.model.fatigue_coefficient = -0.001,
            .fatigue_over_max => {
                plan.model.fatigue_coefficient = pace_model.fatigue_coefficient_max + 0.001;
            },
            .stop_over_max => plan.model.life_base_stop_s = pace_model.life_base_stop_s_max + 1,
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

/// A valid three-entry plan with fueling: full at the start, nothing at the LifeBase, and the
/// finish. Fills the caller's arrays, which the plan borrows.
fn fuel_plan_test(
    entries: *[3]PlanEntry,
    supplies: *[3]fueling.Supply,
    carry: *[3]?fueling.Carry,
) Plan {
    entries.* = .{
        entry_test("Start", 0, 0, 0),
        entry_test("LB1", 30_000, 4 * 3600, 1800),
        entry_test("Finish", 60_000, 9 * 3600, 0),
    };
    supplies.* = .{ .full, .none, .none };
    const fuel: fueling.Fueling = .{
        .carbs_g_per_h = 70,
        .fluid_ml_per_h = 500,
        .sodium_mg_per_h = 400,
        .reserve_s = 1800,
        .supplies = supplies,
    };
    var times: [3]fueling.Times = undefined;
    fueling.times_from_entries(entries, &times);
    fueling.carry_compute(&times, &fuel, carry);
    const fuel_plan: fueling.FuelPlan = .{ .fueling = fuel, .carry = carry };
    return plan_build("<gpx/>", "Loop", 60_000, entries, &.{}, &fuel_plan);
}

test "plan_build and plan_read: fueling round-trips, and the reader owns it" {
    var entries: [3]PlanEntry = undefined;
    var supplies: [3]fueling.Supply = undefined;
    var carry: [3]?fueling.Carry = undefined;
    const plan = fuel_plan_test(&entries, &supplies, &carry);
    // 9 h to the finish and the 30 min reserve: 9.5 h at 70 g/h is 665 g.
    try testing.expectEqual(@as(f64, 665), plan.carry[0].?.carbs_g.?);
    try testing.expectEqual(@as(f64, 4750), plan.carry[0].?.fluid_ml);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try plan_write(&out.writer, &plan);
    const bytes = try testing.allocator.dupe(u8, out.written());
    const parsed = try plan_read(testing.allocator, bytes);
    defer parsed.deinit();
    @memset(bytes, 0);
    testing.allocator.free(bytes);

    const fuel = parsed.value.model.fueling.?;
    try testing.expectEqual(@as(f64, 70), fuel.carbs_g_per_h);
    try testing.expectEqual(@as(u32, 1800), fuel.reserve_s);
    try testing.expectEqualSlices(fueling.Supply, &supplies, fuel.supplies);
    try testing.expectEqual(@as(usize, 3), parsed.value.carry.len);
    try testing.expectEqual(carry[0].?.sodium_mg, parsed.value.carry[0].?.sodium_mg);
    try testing.expect(parsed.value.carry[1] == null and parsed.value.carry[2] == null);
}

test "plan_read: a v1 file reads with no fueling, and a v1 file with fueling is invalid" {
    const allocator = testing.allocator;
    var entries: [2]PlanEntry = undefined;
    const plan = plan_test(&entries);
    const v2 = try json_test(&plan);
    defer allocator.free(v2);
    // v1's exact shape: no fueling key, no carry key.
    const no_fueling = try std.mem.replaceOwned(u8, allocator, v2, ",\"fueling\":null", "");
    defer allocator.free(no_fueling);
    const no_carry = try std.mem.replaceOwned(u8, allocator, no_fueling, ",\"carry\":[]", "");
    defer allocator.free(no_carry);
    const v1 = try std.mem.replaceOwned(
        u8,
        allocator,
        no_carry,
        "\"schema_version\":2",
        "\"schema_version\":1",
    );
    defer allocator.free(v1);
    try testing.expect(std.mem.indexOf(u8, v1, "fueling") == null);
    try testing.expect(std.mem.indexOf(u8, v1, "carry") == null);

    const parsed = try plan_read(allocator, v1);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.value.schema_version);
    try testing.expect(parsed.value.model.fueling == null);
    try testing.expectEqual(@as(usize, 0), parsed.value.carry.len);

    var fuel_entries: [3]PlanEntry = undefined;
    var supplies: [3]fueling.Supply = undefined;
    var carry: [3]?fueling.Carry = undefined;
    var fueled = fuel_plan_test(&fuel_entries, &supplies, &carry);
    fueled.schema_version = 1;
    try testing.expect(!plan_valid(&fueled));
    const bytes = try json_test(&fueled);
    defer allocator.free(bytes);
    try testing.expectError(error.PlanInvalid, plan_read(allocator, bytes));
}

test "plan_read: each broken fueling invariant is PlanInvalid" {
    const Break = enum {
        supplies_short,
        carry_short,
        carry_off_by_one,
        carry_where_none,
        carry_without_fueling,
        rate_negative,
        reserve_changed,
    };
    for (std.enums.values(Break)) |which| {
        var entries: [3]PlanEntry = undefined;
        var supplies: [3]fueling.Supply = undefined;
        var carry: [3]?fueling.Carry = undefined;
        var plan = fuel_plan_test(&entries, &supplies, &carry);
        try testing.expect(plan_valid(&plan));
        switch (which) {
            .supplies_short => plan.model.fueling.?.supplies = supplies[0..2],
            .carry_short => plan.carry = carry[0..2],
            .carry_off_by_one => carry[0].?.carbs_g.? += 1,
            .carry_where_none => carry[1] = .{ .fluid_ml = 0, .carbs_g = 0, .sodium_mg = 0 },
            .carry_without_fueling => plan.model.fueling = null,
            .rate_negative => plan.model.fueling.?.carbs_g_per_h = -1,
            // The carry no longer matches its inputs: the editor must recompute it.
            .reserve_changed => plan.model.fueling.?.reserve_s += 60,
        }
        try testing.expect(!plan_valid(&plan));
        const bytes = try json_test(&plan);
        defer testing.allocator.free(bytes);
        try testing.expectError(error.PlanInvalid, plan_read(testing.allocator, bytes));
    }
}
