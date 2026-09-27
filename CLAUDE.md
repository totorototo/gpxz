# gpxz — project rules

## Project

Minimal Zig library + CLI for GPX trail routes: parsing, distances, denoised D+/D-, climbs,
sections and stages between typed waypoints, and a pace model that estimates durations and
cutoff margins. Extracted from terminus's `zig/` directory (history kept with
`git subtree split`); terminus still builds its own copy through Zigar, and the two are not
linked yet.

- `src/root.zig`: the library entry point. Re-exports every module and the main types.
- `src/main.zig`: the CLI (`zig build run -- [--json] [--pace <s/km>] [--fatigue <k>]
  [--life-base-stop <s>] file.gpx`). All I/O lives here. The default output is a text
  summary; `--json` prints totals, climbs, waypoints, legs, sections and stages, without the
  per-point arrays.
- The library is pure and does no I/O: bytes and slices in, owned structs out.
  - `gpx.zig`: GPX parsing by manual `std.mem` scanning (no XML library). `parse(allocator,
    bytes, &settings)` → `GPXData { trace, waypoints, legs, sections, stages, metadata,
    points_full_resolution }` is the main entry point. A malformed element is a
    `ParseError`, never skipped.
  - `pace_model.zig`'s `Settings` (base pace, fatigue coefficient, LifeBase stop, weather)
    is passed by pointer everywhere the pace model runs; its defaults are the presets.
  - `trace.zig`: `Trace`, parallel per-point arrays (cumulative distance, D+, D-, slopes,
    pace factors) plus peaks, valleys and climbs. Points are `[3]f64` indexed by
    `gps_point.zig`'s `latitude_index`, `longitude_index`, `elevation_index`.
  - `gps_point.zig` (Haversine, bearing), `elevation.zig` (denoised D+/D-), `extrema.zig`
    (AMPD peaks and valleys), `climbs.zig` (Garmin-style qualification), `simplify.zig`
    (Douglas-Peucker), `time.zig` (ISO 8601 → epoch).
  - `leg.zig`, `section.zig`, `stage.zig`: stats between waypoints; sections and stages are
    thin wrappers over `calibration.zig` (a-priori interval stats and live recalibration).
  - `minetti.zig` (slope cost), `pace_model.zig` (slope × fatigue × circadian × weather),
    `segment.zig` (per-point metrics), `soundscape.zig` (audio frames, terminus-specific).
- **Names are JSON keys**: struct fields serialize as-is in `--json` and reach JavaScript
  through Zigar in terminus, so renaming a public field changes both outputs.
- **Error policy**: an error is for invalid external bytes (a malformed GPX). An `assert` is
  for library invariants, so a failed assert means a bug in gpxz, never a bad file.
- **Targets Zig 0.16.0**: I/O needs an explicit `std.Io`, `main` takes `std.process.Init`,
  and containers are unmanaged (`.empty` + pass the allocator on each call).
  Don't write pre-0.16 idioms.

## Coding style: TigerBeetle (TIGER_STYLE)

Follow https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md. Key points:

- **Safety > performance > developer experience**, in that order.
- **Assertions everywhere**: at least 2 per function on average. Assert arguments, return values, pre/postconditions and invariants.
- **Paired assertions**: check the same property in two places (e.g. before writing data and after reading it back).
- **Memory allocation (relaxed vs. TigerBeetle)**: dynamic allocation after init is allowed.
  Pass allocators explicitly, make ownership clear, and pair every allocation with a
  `defer`/`errdefer` free. Sizes that come from untrusted input must still be bounded.
- **Put a limit on everything**: every loop and queue has a fixed upper bound. No unbounded recursion.
- **Explicit sized types** (`u32`, `u64`); avoid `usize` except for indexing.
- **Functions ≤ 70 lines**. Keep control flow simple, centralize branching in the parent, keep leaf functions pure.
- **Handle every error**; never discard one silently.
- **Naming**: `snake_case` for functions and variables. No abbreviations. Put units and qualifiers last, in descending significance (`latency_ms_max`, not `max_latency_ms`).
- **Line length ≤ 100**, and run `zig fmt`.
- **Comments explain why**, written as full sentences.
- **Declare variables in the smallest possible scope**, as close to use as possible.
- **Pass large args as `*const`** to avoid copies.

## Negative space programming

Assert what *must not* happen, in addition to what should:
- Assert the positive space (the expected valid state) **and** the negative space (invalid states that must be impossible).
- Assert at boundaries where valid data turns invalid (e.g. `assert(index < len)` and `assert(count <= count_max)`).
- Prefer `unreachable` for states that can't occur. Don't write silent fallbacks.
- Handle each case of a condition explicitly. A missing `else` should be a deliberate choice.

## Testing: required for every change

- **Every** feature, helper or function you add ships with unit tests (`test "..." {}` blocks) in the same change.
- Tests cover the valid space, the edge cases (0, 1, max, max+1) and the invalid space.
- Run `zig build test --summary all` and confirm it passes before calling any work done. Plain
  `zig build test` prints nothing on success, so the summary is what shows the pass counts.
- CI (`.github/workflows/ci.yml`) also checks `zig fmt`, the 100-column limit and ReleaseSafe,
  so run those locally too before pushing.
