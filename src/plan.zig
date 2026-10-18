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
    entries_assert_valid(entries, distance_m);
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
    return plan;
}

/// The invariants `calibration.plan_compute` guarantees, so a plan never carries entries that
/// a reader would have to reject.
fn entries_assert_valid(entries: []const PlanEntry, distance_m: f64) void {
    var departure_s_previous: f64 = 0.0;
    var distance_m_previous: f64 = 0.0;
    for (entries) |*entry| {
        assert(entry.stop_s >= 0);
        assert(entry.duration_s_arrival >= departure_s_previous);
        assert(entry.duration_s_departure == entry.duration_s_arrival + entry.stop_s);
        assert(entry.distance_m >= distance_m_previous);
        // Distances count from the first checkpoint, so they never pass the whole trace.
        assert(entry.distance_m <= distance_m);
        departure_s_previous = entry.duration_s_departure;
        distance_m_previous = entry.distance_m;
    }
}

/// Writes `plan` as `plan.json`: indented JSON with a trailing newline.
pub fn plan_write(writer: *std.Io.Writer, plan: *const Plan) std.Io.Writer.Error!void {
    assert(plan.schema_version == schema_version);
    assert(plan.course.sha256.len == 64);
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
