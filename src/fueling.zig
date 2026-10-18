//! Fueling: what a runner eats and drinks, and what they leave each checkpoint with. It is race
//! strategy, so it lives in `plan.json` and never in the GPX; a checkpoint's `<type>` only
//! seeds the default supply. It changes no time: it is a pass over the times the pace model
//! already produced, so `pace_model.Settings` and `PlanEntry` know nothing of it.

const std = @import("std");
const assert = std.debug.assert;

const PlanEntry = @import("calibration.zig").PlanEntry;

const s_per_hour: f64 = 3600;

/// What a checkpoint refills. `water` refills fluid only; `full` (an aid station with food, a
/// LifeBase, a drop bag) refills everything. Ordered: each level refills what the one before
/// it does.
pub const Supply = enum { none, water, full };

/// The runner's hourly targets and where they refill.
pub const Fueling = struct {
    carbs_g_per_h: f64,
    fluid_ml_per_h: f64,
    sodium_mg_per_h: f64,
    /// Added to the time of every carry, so a bad patch doesn't leave the runner short.
    reserve_s: u32,
    /// One per plan entry, in race order. Borrowed.
    supplies: []const Supply,
};

/// What to leave a checkpoint with, each amount until the next point that refills it. Whole
/// numbers stored as f64: rounded up so the runner is never short, and f64 so a long, slow
/// plan can't overflow. Null carbs and sodium at a water point: the runner keeps what they
/// have.
pub const Carry = struct {
    fluid_ml: f64,
    carbs_g: ?f64,
    sodium_mg: ?f64,
};

/// The fueling a plan records: its inputs and the carry they give, one per entry. One value,
/// so a plan can't hold one without the other.
pub const FuelPlan = struct {
    fueling: Fueling,
    carry: []const ?Carry,
};

/// One checkpoint's race times: the only part of a plan entry fueling reads, so a live
/// estimate (terminus) can be passed without building plan entries.
pub const Times = struct { arrival_s: f64, departure_s: f64 };

/// Whether `fueling` can be used for a plan of `entry_count` entries: finite, non-negative
/// rates and one supply per entry. There are no upper bounds here: those are the apps' form
/// bounds, and f64 arithmetic carries any finite rate.
pub fn fueling_valid(fueling: *const Fueling, entry_count: usize) bool {
    const rates = [_]f64{ fueling.carbs_g_per_h, fueling.fluid_ml_per_h, fueling.sodium_mg_per_h };
    for (rates) |rate| {
        if (!std.math.isFinite(rate) or !(rate >= 0)) return false;
    }
    return fueling.supplies.len == entry_count;
}

/// The supplies a runner starts from before choosing: `full` at the Start and every LifeBase,
/// `none` elsewhere.
pub fn supplies_default(entries: []const PlanEntry, out: []Supply) void {
    assert(entries.len == out.len);
    for (entries, out) |*entry, *supply| {
        const type_name = entry.type_name orelse "";
        const full = std.mem.eql(u8, type_name, "Start") or std.mem.eql(u8, type_name, "LifeBase");
        supply.* = if (full) .full else .none;
    }
    // A water point is the runner's choice: no `<type>` implies one.
    for (out) |supply| assert(supply != .water);
}

pub fn times_from_entries(entries: []const PlanEntry, out: []Times) void {
    assert(entries.len == out.len);
    for (entries, out) |*entry, *times| {
        assert(entry.duration_s_departure >= entry.duration_s_arrival);
        times.* = .{
            .arrival_s = entry.duration_s_arrival,
            .departure_s = entry.duration_s_departure,
        };
    }
}

/// Writes the carry at each checkpoint: for each resource, the amount for the time from
/// departure here to arrival at the next point that refills it (or the last entry), plus the
/// reserve. Stops in between count: the runner keeps eating while standing at a time barrier.
/// Null where the supply is `none`, and at the last entry, which has nothing after it.
pub fn carry_compute(times: []const Times, fueling: *const Fueling, out: []?Carry) void {
    assert(fueling_valid(fueling, times.len));
    assert(times.len == out.len);
    if (times.len == 0) return;

    var next = Next.init(times[times.len - 1].arrival_s);
    var number = times.len;
    while (number > 0) {
        number -= 1;
        if (number > 0) assert(times[number].arrival_s >= times[number - 1].departure_s);
        const supply = fueling.supplies[number];
        out[number] = if (number == times.len - 1)
            null
        else
            carry_one(supply, times[number].departure_s, &next, fueling);
        next.update(supply, times[number].arrival_s);
    }
    assert(out[out.len - 1] == null);
}

/// Whether `carry` is exactly what `carry_compute` gives for `entries`. Allocation-free, for
/// `plan_valid`: the same backward scan, comparing as it goes. The entries must already be
/// valid (`plan.entries_valid`), so their times run forward.
pub fn carry_matches(
    entries: []const PlanEntry,
    fueling: *const Fueling,
    carry: []const ?Carry,
) bool {
    assert(fueling_valid(fueling, entries.len));
    if (carry.len != entries.len) return false;
    if (entries.len == 0) return true;

    var next = Next.init(entries[entries.len - 1].duration_s_arrival);
    var number = entries.len;
    while (number > 0) {
        number -= 1;
        const entry = &entries[number];
        if (number > 0) {
            assert(entry.duration_s_arrival >= entries[number - 1].duration_s_departure);
        }
        const supply = fueling.supplies[number];
        const expected = if (number == entries.len - 1)
            null
        else
            carry_one(supply, entry.duration_s_departure, &next, fueling);
        if (!carry_eql(carry[number], expected)) return false;
        next.update(supply, entry.duration_s_arrival);
    }
    return true;
}

/// The arrival at the next point that refills each resource, seen from a backward scan.
const Next = struct {
    arrival_s_water: f64,
    arrival_s_full: f64,

    /// Before any refill point is seen, the next one is the last entry.
    fn init(arrival_s_last: f64) Next {
        assert(arrival_s_last >= 0);
        return .{ .arrival_s_water = arrival_s_last, .arrival_s_full = arrival_s_last };
    }

    fn update(next: *Next, supply: Supply, arrival_s: f64) void {
        assert(arrival_s <= next.arrival_s_water and arrival_s <= next.arrival_s_full);
        switch (supply) {
            .none => {},
            .water => next.arrival_s_water = arrival_s,
            .full => {
                next.arrival_s_water = arrival_s;
                next.arrival_s_full = arrival_s;
            },
        }
        assert(next.arrival_s_water <= next.arrival_s_full);
    }
};

fn carry_one(supply: Supply, departure_s: f64, next: *const Next, fueling: *const Fueling) ?Carry {
    assert(departure_s <= next.arrival_s_water);
    assert(next.arrival_s_water <= next.arrival_s_full);
    const duration_s_water = next.arrival_s_water - departure_s;
    const duration_s_full = next.arrival_s_full - departure_s;
    return switch (supply) {
        .none => null,
        .water => .{
            .fluid_ml = amount(fueling.fluid_ml_per_h, duration_s_water, fueling.reserve_s),
            .carbs_g = null,
            .sodium_mg = null,
        },
        .full => .{
            .fluid_ml = amount(fueling.fluid_ml_per_h, duration_s_water, fueling.reserve_s),
            .carbs_g = amount(fueling.carbs_g_per_h, duration_s_full, fueling.reserve_s),
            .sodium_mg = amount(fueling.sodium_mg_per_h, duration_s_full, fueling.reserve_s),
        },
    };
}

/// `rate_per_h` over `duration_s` and the reserve, rounded up to a whole number.
fn amount(rate_per_h: f64, duration_s: f64, reserve_s: u32) f64 {
    assert(rate_per_h >= 0 and std.math.isFinite(rate_per_h));
    assert(duration_s >= 0);
    const reserve: f64 = @floatFromInt(reserve_s);
    const result = @ceil(rate_per_h * (duration_s + reserve) / s_per_hour);
    assert(result >= 0);
    return result;
}

/// Exact, as `plan_valid` compares times: the reader recomputes with the same arithmetic.
/// A non-finite stored amount never matches, since `carry_one` only computes finite ones
/// from finite times.
fn carry_eql(stored: ?Carry, expected: ?Carry) bool {
    const a = stored orelse return expected == null;
    const b = expected orelse return false;
    if (!std.math.isFinite(a.fluid_ml) or a.fluid_ml != b.fluid_ml) return false;
    return optional_eql(a.carbs_g, b.carbs_g) and optional_eql(a.sodium_mg, b.sodium_mg);
}

fn optional_eql(stored: ?f64, expected: ?f64) bool {
    const a = stored orelse return expected == null;
    const b = expected orelse return false;
    return std.math.isFinite(a) and a == b;
}

const testing = std.testing;

/// 60 g/h carbs, 600 ml/h fluid, 360 mg/h sodium: one hour is 60, 600, 360.
fn fueling_test(supplies: []const Supply) Fueling {
    return .{
        .carbs_g_per_h = 60,
        .fluid_ml_per_h = 600,
        .sodium_mg_per_h = 360,
        .reserve_s = 0,
        .supplies = supplies,
    };
}

fn compute_test(times: []const Times, fueling: *const Fueling) ![]?Carry {
    const out = try testing.allocator.alloc(?Carry, times.len);
    carry_compute(times, fueling, out);
    return out;
}

const hour_s = s_per_hour;

test "carry_compute: one refill at the start lasts to the finish" {
    const times = [_]Times{
        .{ .arrival_s = 0, .departure_s = 0 },
        .{ .arrival_s = 2 * hour_s, .departure_s = 2 * hour_s },
        .{ .arrival_s = 3 * hour_s, .departure_s = 3 * hour_s },
    };
    const fueling = fueling_test(&.{ .full, .none, .none });
    const carry = try compute_test(&times, &fueling);
    defer testing.allocator.free(carry);
    try testing.expectEqual(@as(f64, 1800), carry[0].?.fluid_ml);
    try testing.expectEqual(@as(f64, 180), carry[0].?.carbs_g.?);
    try testing.expectEqual(@as(f64, 1080), carry[0].?.sodium_mg.?);
    try testing.expect(carry[1] == null);
    try testing.expect(carry[2] == null);
}

test "carry_compute: a water point resets fluid, and carbs run on to the next full point" {
    const times = [_]Times{
        .{ .arrival_s = 0, .departure_s = 0 },
        .{ .arrival_s = 1 * hour_s, .departure_s = 1 * hour_s },
        .{ .arrival_s = 3 * hour_s, .departure_s = 3 * hour_s },
        .{ .arrival_s = 4 * hour_s, .departure_s = 4 * hour_s },
    };
    const fueling = fueling_test(&.{ .full, .water, .full, .none });
    const carry = try compute_test(&times, &fueling);
    defer testing.allocator.free(carry);
    // From the start: fluid to the water point (1 h), carbs to the next full point (3 h).
    try testing.expectEqual(@as(f64, 600), carry[0].?.fluid_ml);
    try testing.expectEqual(@as(f64, 180), carry[0].?.carbs_g.?);
    // At the water point: fluid for 2 h, nothing else.
    try testing.expectEqual(@as(f64, 1200), carry[1].?.fluid_ml);
    try testing.expect(carry[1].?.carbs_g == null and carry[1].?.sodium_mg == null);
    // At the second full point: 1 h to the finish.
    try testing.expectEqual(@as(f64, 60), carry[2].?.carbs_g.?);
    try testing.expect(carry[3] == null);
}

test "carry_compute: a stop between counts, a stop at the refill point does not" {
    // The runner stops 1 h at the refill point and 30 min at the time barrier after it.
    const times = [_]Times{
        .{ .arrival_s = 0, .departure_s = hour_s },
        .{ .arrival_s = 2 * hour_s, .departure_s = 2.5 * hour_s },
        .{ .arrival_s = 3.5 * hour_s, .departure_s = 3.5 * hour_s },
    };
    const fueling = fueling_test(&.{ .full, .none, .none });
    const carry = try compute_test(&times, &fueling);
    defer testing.allocator.free(carry);
    // From departure (1 h) to the finish (3.5 h): 2.5 h.
    try testing.expectEqual(@as(f64, 150), carry[0].?.carbs_g.?);
}

test "carry_compute: the reserve, rounding up, and zero rates" {
    const times = [_]Times{
        .{ .arrival_s = 0, .departure_s = 0 },
        .{ .arrival_s = 1001, .departure_s = 1001 },
    };
    var fueling = fueling_test(&.{ .full, .none });
    fueling.reserve_s = 1799;
    const carry = try compute_test(&times, &fueling);
    defer testing.allocator.free(carry);
    // 2800 s at 60 g/h is 46.67 g: rounded up to 47.
    try testing.expectEqual(@as(f64, 47), carry[0].?.carbs_g.?);
    // A whole amount stays whole: 2800 s at 3600 ml/h is 2800 ml.
    fueling.fluid_ml_per_h = 3600;
    carry_compute(&times, &fueling, carry);
    try testing.expectEqual(@as(f64, 2800), carry[0].?.fluid_ml);

    fueling.carbs_g_per_h = 0;
    fueling.fluid_ml_per_h = 0;
    fueling.sodium_mg_per_h = 0;
    carry_compute(&times, &fueling, carry);
    try testing.expectEqual(@as(f64, 0), carry[0].?.fluid_ml);
    try testing.expectEqual(@as(f64, 0), carry[0].?.carbs_g.?);
}

test "carry_compute: zero and one entries" {
    const fueling_empty = fueling_test(&.{});
    const none = try compute_test(&.{}, &fueling_empty);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    const fueling_one = fueling_test(&.{.full});
    const one = try compute_test(&.{.{ .arrival_s = 0, .departure_s = 0 }}, &fueling_one);
    defer testing.allocator.free(one);
    try testing.expect(one[0] == null);
}

fn entry_test(type_name: ?[]const u8, arrival_s: f64, stop_s: f64) PlanEntry {
    return .{
        .name = "Checkpoint",
        .type_name = type_name,
        .index = 0,
        .latitude = 45.0,
        .longitude = 6.0,
        .elevation_m = 1000.0,
        .distance_m = 0,
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

test "supplies_default: full at the Start and LifeBases, none elsewhere" {
    const entries = [_]PlanEntry{
        entry_test("Start", 0, 0),
        entry_test("TimeBarrier", 3600, 0),
        entry_test(null, 5000, 0),
        entry_test("LifeBase", 9000, 1800),
        entry_test("Arrival", 20000, 0),
    };
    var supplies: [entries.len]Supply = undefined;
    supplies_default(&entries, &supplies);
    const expected = [_]Supply{ .full, .none, .none, .full, .none };
    try testing.expectEqualSlices(Supply, &expected, &supplies);
}

test "times_from_entries and carry_matches agree with carry_compute" {
    const entries = [_]PlanEntry{
        entry_test("Start", 0, 0),
        entry_test("Water", 4000, 120),
        entry_test("LifeBase", 9000, 1800),
        entry_test("Arrival", 20000, 0),
    };
    const supplies = [_]Supply{ .full, .water, .full, .none };
    var fueling = fueling_test(&supplies);
    fueling.reserve_s = 900;
    var times: [entries.len]Times = undefined;
    times_from_entries(&entries, &times);
    try testing.expectEqual(@as(f64, 4120), times[1].departure_s);
    var carry: [entries.len]?Carry = undefined;
    carry_compute(&times, &fueling, &carry);
    try testing.expect(carry_matches(&entries, &fueling, &carry));

    // One gram off, a carry where the supply is none, a missing one, the wrong length, and a
    // non-finite amount: none match.
    var broken = carry;
    broken[0].?.carbs_g.? += 1;
    try testing.expect(!carry_matches(&entries, &fueling, &broken));
    broken = carry;
    broken[3] = .{ .fluid_ml = 0, .carbs_g = null, .sodium_mg = null };
    try testing.expect(!carry_matches(&entries, &fueling, &broken));
    broken = carry;
    broken[1] = null;
    try testing.expect(!carry_matches(&entries, &fueling, &broken));
    try testing.expect(!carry_matches(&entries, &fueling, carry[0..3]));
    broken = carry;
    broken[1].?.fluid_ml = std.math.inf(f64);
    try testing.expect(!carry_matches(&entries, &fueling, &broken));
    // Carbs at a water point, where the runner can't refill them.
    broken = carry;
    broken[1].?.carbs_g = 0;
    try testing.expect(!carry_matches(&entries, &fueling, &broken));
}

test "fueling_valid: rates finite and non-negative, one supply per entry" {
    const supplies = [_]Supply{ .full, .none };
    var fueling = fueling_test(&supplies);
    try testing.expect(fueling_valid(&fueling, 2));
    try testing.expect(!fueling_valid(&fueling, 3));
    try testing.expect(!fueling_valid(&fueling, 1));
    fueling.carbs_g_per_h = -0.001;
    try testing.expect(!fueling_valid(&fueling, 2));
    fueling.carbs_g_per_h = std.math.nan(f64);
    try testing.expect(!fueling_valid(&fueling, 2));
    fueling.carbs_g_per_h = 60;
    fueling.sodium_mg_per_h = std.math.inf(f64);
    try testing.expect(!fueling_valid(&fueling, 2));
}
