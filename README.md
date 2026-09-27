# gpxz

A Zig library and CLI for GPX trail routes: parsing, distances, denoised D+/D-, climbs,
sections and stages between typed waypoints, and a pace model (Minetti slope cost, fatigue,
circadian, weather) that estimates durations and cutoff margins.

The code was extracted from [terminus](https://github.com/totorototo/terminus), where it runs as WebAssembly in
the browser. The library is pure: it works on in-memory bytes and does no I/O.

Requires Zig 0.16.0.

## CLI

```sh
zig build run -- route.gpx                # text summary
zig build run -- --json route.gpx         # the same, as JSON
zig build run -- --pace 420 --fatigue 0.004 --life-base-stop 1800 route.gpx
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--json` | off | Print totals, climbs, waypoints, legs, sections and stages as JSON |
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

## Tests

```sh
zig build test --summary all
```

Benchmarks are a separate step, always built in ReleaseFast. They print timings and never fail
on them:

```sh
zig build bench
```
