# plan.json v2: fueling

Status: `fueling.zig` and `plan.zig` implemented; CLI flags, Regimen and Terminus to do. Owner: gpxz (`src/plan.zig`, new `src/fueling.zig`).
Consumers: Regimen (sets it), Terminus (reads it, recomputes it live).

## Why

A runner plans what to eat and drink as well as when to arrive: hourly targets, where they
will refill, and therefore what to leave each refill point with. All of it is race strategy,
so it lives in `plan.json`, never in the GPX: Waymark and the course carry no supply data.
A checkpoint's `<type>` only seeds a default.

## Decisions

1. **Fueling is not a pace model input.** It changes no time, so it stays out of
   `pace_model.Settings`, `gpx.parse` and `calibration.plan_compute`. It is a pass over the
   times the pace model already produced. `PlanEntry`, `GPXData.plan`, `--json` and
   Terminus's Zigar types do not change.
2. **Inputs in `model.fueling`, outputs in a top-level `carry`.** `model` stays "everything
   needed to recompute the plan", so Regimen and Terminus restore a plan from `model` alone,
   as they do today. `entries` keeps v1's exact shape.
3. **Per-checkpoint data is a dense array parallel to `entries`.** `supplies[i]` and
   `carry[i]` belong to `entries[i]`. No hidden default a reader has to know; `plan_valid`
   checks the lengths. The course is pinned by SHA-256, so the order can't shift.
4. **Three supply levels: `none`, `water`, `full`.** `water` refills fluid; `full` (aid
   station with food, LifeBase, drop bag) refills everything. "Food without water" does not
   happen in practice, so a fourth level would only add a case.
5. **Carry covers elapsed time**, from departure here to arrival at the next point that refills
   that resource, plus a reserve. Stops at checkpoints in between count: the runner keeps
   eating while standing at a time barrier.
6. **Carry is a whole number stored as f64** (`@ceil`). Rounding up never leaves the runner
   short; f64 can't overflow on a long, slow plan where u32 grams could; the validator
   recomputes and compares exactly, like `departure == arrival + stop`.
7. **One function computes carry, everywhere.** Regimen's export and Terminus's live estimate
   both call `fueling.carry_compute`, so the two apps can't drift.

## Schema

```json
{
  "schema_version": 2,
  "course": { "name": "GRP 160", "sha256": "…", "distance_m": 160000 },
  "model": {
    "pace_base_s_per_km": 420,
    "fatigue_coefficient": 0.002,
    "life_base_stop_s": 1800,
    "fueling": {
      "carbs_g_per_h": 70,
      "fluid_ml_per_h": 500,
      "sodium_mg_per_h": 400,
      "reserve_s": 1800,
      "supplies": ["full", "none", "water", "full", "water", "none"]
    }
  },
  "entries": [ "… six v1 entries, unchanged …" ],
  "carry": [
    { "fluid_ml": 1650, "carbs_g": 455, "sodium_mg": 2600 },
    null,
    { "fluid_ml": 900, "carbs_g": null, "sodium_mg": null },
    { "fluid_ml": 1200, "carbs_g": 520, "sodium_mg": 2980 },
    { "fluid_ml": 1100, "carbs_g": null, "sodium_mg": null },
    null
  ]
}
```

- The numbers are illustrative, not computed.
- `model.fueling` is `null` when the runner plans no fueling; `carry` is then `[]`.
- `carry[i]` is `null` where `supplies[i]` is `none`, and always at the last entry (nothing
  after it). At a `water` point `carbs_g` and `sodium_mg` are `null`: the runner keeps what
  they have.

## `src/fueling.zig`

```zig
pub const Supply = enum { none, water, full };

pub const Fueling = struct {
    carbs_g_per_h: f64,
    fluid_ml_per_h: f64,
    sodium_mg_per_h: f64,
    reserve_s: u32,
    /// One per plan entry, in race order. Borrowed.
    supplies: []const Supply,
};

/// What to leave a checkpoint with, each amount until the next point that refills it.
pub const Carry = struct {
    fluid_ml: f64,
    carbs_g: ?f64,
    sodium_mg: ?f64,
};

/// One checkpoint's race times: the only part of a plan entry fueling reads.
pub const Times = struct { arrival_s: f64, departure_s: f64 };

pub fn fueling_valid(fueling: *const Fueling, entry_count: usize) bool;
pub fn supplies_default(entries: []const PlanEntry, out: []Supply) void;
pub fn times_from_entries(entries: []const PlanEntry, out: []Times) void;
pub fn carry_compute(times: []const Times, fueling: *const Fueling, out: []?Carry) void;
```

`Times` instead of `PlanEntry` lets Terminus pass live ETAs without building plan entries.

### `supplies_default`

`<type>` `Start` and `LifeBase` → `full`; every other checkpoint → `none`. Used only when the
runner hasn't chosen yet. What the plan stores is always the resolved array.

### `carry_compute`

For each entry `i` and each resource (fluid refilled by `water` and `full`; carbs and sodium
by `full` only):

- If `i` is the last entry, or `supplies[i]` doesn't refill the resource: `null` (the whole
  `Carry` is `null` when `supplies[i] == .none`).
- Else `j` = the first entry after `i` whose supply refills the resource, or the last entry
  if none does, and

  `amount = @ceil(rate_per_h * (times[j].arrival_s - times[i].departure_s + reserve_s) / 3600)`

One backward scan keeps the next refill index per resource: O(n), bounded by
`times.len`.

Assertions: `times.len == fueling.supplies.len == out.len`; each arrival ≥ the previous
departure (as `entries_valid`); every amount finite and ≥ 0; the last `out` is `null`;
`out[i] == null` exactly when `supplies[i] == .none` or `i` is last.

### `fueling_valid`

Rates finite and ≥ 0, `supplies.len == entry_count`. No upper bounds here: they are form
bounds and live in the apps (`regimen.zig`, mirrored in `src/plan/settings.js`). gpxz only
needs values its arithmetic can carry, and f64 carry can't overflow.

## `src/plan.zig`

- `schema_version = 2`; new `schema_version_read_min = 1`.
- `Model` gains `fueling: ?fueling.Fueling = null`. `Plan` gains
  `carry: []const ?fueling.Carry = &.{}`. The defaults make a v1 file parse into v2's types
  with no migration code.
- `plan_build(bytes, name, distance_m, entries, settings, fueling: ?*const Fueling,
  carry: []const ?Carry)`. It still borrows everything; the caller runs `carry_compute`
  first.
- `plan_valid`, added checks:
  - `schema_version` is 1 or 2.
  - v1: `model.fueling == null` and `carry.len == 0` (a v1 file with v2 keys is invalid).
  - v2, fueling `null`: `carry.len == 0`.
  - v2, fueling set: `fueling_valid(fueling, entries.len)`, `carry.len == entries.len`, and
    every `carry[i]` is exactly what `carry_compute` would give. `plan_valid` stays
    allocation-free: it walks the entries backwards like `carry_compute` does, and both
    call the same leaf, `carry_one(supply, departure_s, arrival_s_next_water,
    arrival_s_next_full, fueling)`, comparing as it goes instead of filling a buffer.
- `plan_read`: version check becomes `schema_version_read_min <= v <= schema_version`.
- `plan_write`: asserts `schema_version == 2`. gpxz only writes the current version.
- `ReadError` is unchanged.

## CLI (`src/main.zig`)

`--plan` gains `--carbs <g/h>`, `--fluid <ml/h>`, `--sodium <mg/h>`, `--reserve <s>`. Any of
them turns fueling on (the rest default to 0); supplies are always `supplies_default`. No flag
for per-checkpoint supplies: that's Regimen's job.

## Regimen (`zig/regimen.zig`, `src/`)

- `PlanSettings` gains `fueling: ?FuelingSettings = null`, where `supplies` may be empty,
  which means "use the defaults". After `parse`: empty → `supplies_default`; a length other
  than `entries.len` → `error.SuppliesMismatch`; rates outside the form bounds →
  `error.SettingsInvalid`. Then `carry_compute`, then `plan_build`.
- Form bounds (first guess): carbs 0–150 g/h, fluid 0–1500 ml/h, sodium 0–3000 mg/h,
  reserve 0–180 min. Mirrored in `src/plan/settings.js`.
- The page reads the resolved `model.fueling.supplies` from the plan it gets back to draw
  the Refill selects, so there is no separate defaults export.
- `openPlan`: `OpenReport.model` now carries `fueling`. A plan for another course whose
  supplies don't fit → the page falls back to the defaults and says so.
- To check: Zigar passing a JS array of strings as `[]const Supply`. If it can't, `supplies`
  crosses as a JSON string like the rest of the boundary.

UI:
- **ModelPanel:** a "Fueling" group under "Model", off by default (off = `fueling: null`):
  carbs, fluid, sodium per hour, reserve in minutes.
- **PlanTable:** a Refill column with a select per row (none / water / full); a value that
  differs from the default is marked. A "Leave with" column: `455 g · 1.65 L · 2.6 g Na` at a
  full point, `0.9 L` at a water point, `–` elsewhere.
- **Summary:** race totals of carbs and fluid.

## Terminus (`zig/terminus.zig`, `src/`)

- `readPlanModel` returns `model` with `fueling`; the pace-settings broadcast carries it to
  followers. Today it returns `parsed.value.model` after `defer parsed.deinit()`, which is
  fine for three scalars, but `fueling.supplies` is a slice into the parsed arena: copy it
  with the caller's allocator before the deinit, or it dangles.
- New export `fuelCarry(times, fueling)` → `carry_compute` on the live ETAs. Carry grows
  when the runner is slower than planned.
- The schema bump and the reader ship in the same release: a v1 Terminus refuses v2 plans
  (`SchemaVersionUnsupported` → "Update Terminus").

UI (read-only: Terminus never sets fueling):
- **StoryPace:** the model line adds the targets: `70 g/h · 500 ml/h · 400 mg/h`.
- **StoryNow:** next refill per resource and what to leave it with, from live ETAs.
- **StoryCheckpoints:** a refill badge, and live "leave with" on refill rows.

## Tests (gpxz)

- `carry_compute`: no refill until the finish; water-only points (fluid resets, carbs runs
  on); zero rates give zeros; reserve adds exactly `rate × reserve / 3600` before rounding;
  stops at checkpoints in between count; `@ceil` on whole and fractional amounts.
- `supplies_default`: Start and LifeBase full, the rest none.
- `plan_read`: a v1 file reads with `fueling == null`; a v1 file with `carry` is
  `PlanInvalid`; v3 is `SchemaVersionUnsupported`; the broken-invariant table gains: wrong
  supplies length, wrong carry length, one carry off by 1, carry where supply is none, a
  negative rate.
- Paired: `plan_build` asserts what `plan_read` checks, on a plan with fueling.

## Docs to update with the change

`README.md` (plan.json section, CLI options table) and `CLAUDE.md` (the `plan.zig` bullet,
and a `fueling.zig` bullet); `root.zig` re-exports `fueling`.

## Open questions

- Is sodium worth a v2 field, or carbs and fluid only?
- Should a checkpoint's supply also change its default stop (a `full` point without
  `<stopDuration>` gets a short stop)? Not in v2: stops stay the pace model's.
- Products (gels, bars: `carbs_g` each) to show "6 gels" instead of grams: v3.
