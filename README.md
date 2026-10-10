# gpxz

A Zig library and CLI for GPX trail routes: parsing, distances, denoised D+/D-, climbs and descents,
sections and stages between typed waypoints, and a pace model (Minetti slope cost, fatigue,
circadian, weather) that estimates durations and cutoff margins.

The code was extracted from [terminus](https://github.com/totorototo/terminus), where it runs as WebAssembly in
the browser. The library is pure: it works on in-memory bytes and does no I/O.

Requires Zig 0.17.0.

## CLI

```sh
zig build run -- route.gpx                # text summary
zig build run -- --json route.gpx         # the same, as JSON
zig build run -- --pace 420 --fatigue 0.004 --life-base-stop 1800 route.gpx
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--json` | off | Print totals, climbs, descents, waypoints, legs, sections, stages and the plan (per-checkpoint ETAs) as JSON |
| `--pace <s/km>` | 500 (8:20/km) | Flat-terrain base pace |
| `--fatigue <k>` | 0.002 | Cumulative fatigue coefficient |
| `--life-base-stop <s>` | 3600 | Planned stop at each LifeBase |

The JSON leaves out the per-point arrays (distances, slopes, points), which run to several
MiB on a long route.

Sections and stages are built from typed waypoints (`<type>` of `Start`, `TimeBarrier`,
`LifeBase` or `Arrival`, with a `<time>` for cutoffs).

A malformed file is rejected with an error naming the problem (`CoordinateInvalid`,
`ElevationMissing`, `TimeInvalid`, ...), never parsed with points silently dropped. Every
track point needs an `<ele>`.

## Library

```zig
// build.zig.zon: add gpxz as a dependency, then in build.zig:
const gpxz = b.dependency("gpxz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gpxz", gpxz.module("gpxz"));
```

```zig
const gpxz = @import("gpxz");

// The defaults are the "Moderate" presets: 500 s/km, fatigue 0.002, a 1 h LifeBase stop.
var data = try gpxz.parse(allocator, bytes, &.{ .pace_base_s_per_km = 420 });
defer data.deinit(allocator);
std.debug.print("{d:.1} km\n", .{data.trace.distance_m / 1000.0});
```

## Writing

gpxz also writes: `waypoints_replace` returns a GPX file with its `<wpt>` elements replaced and
everything else (the track, the metadata, any extension gpxz doesn't read) untouched, byte for
byte. The new waypoints go after `<metadata>` and before the routes and tracks, as GPX 1.1
puts them, in the file's own line endings.

```zig
const edited = try gpxz.waypoints_replace(allocator, bytes, waypoints);
defer allocator.free(edited);
```

They are written as the director's files have them (`<ele>`, `<name>`, `<type>`, `<time>`),
plus `<desc>`, `<cmt>` and `<sym>` when set, and `<stopDuration>` (seconds), which gpxz reads
as the planned stop and other tools ignore. Text is escaped, and read back unescaped.

Write the waypoints in route order: gpxz matches each one to the track after the previous one,
so the order of the file is part of what it says. A waypoint that can't be written
(`CoordinateInvalid`, `NumberInvalid`, `TimeOutOfRange`) is an error before anything is built,
and a file that isn't GPX is `NotGpx`.

## Tests

```sh
zig build test --summary all
```

Benchmarks are a separate step, always built in ReleaseFast. They print timings and never fail
on them:

```sh
zig build bench
```
