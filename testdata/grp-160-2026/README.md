# GRP 160 2026: original → extended → plan

One race through the suite's three steps, for tests that need the real thing end to end. The
track is the same in all three: 30899 points, Grand Raid des Pyrénées 2026 Ultra Tour.

| File | Made by | What it is |
|---|---|---|
| `original.gpx` | trail-passion.net ([trace 79697](http://trail-passion.net/trace/?id=79697)), as downloaded | The race director's route: 52 untyped waypoints, no cutoffs |
| `extended.gpx` | Waymark's export: `gpxz.waypoints_replace` | The original with its waypoints replaced by the 15 checkpoints (Start, 11 TimeBarriers, 2 LifeBases, Arrival) and their cutoffs, on the race's clock (`05:00:00+02:00`) |
| `plan.json` | Regimen: `gpxz.plan_build` + `plan_write`, gpxz v0.3.0 | The plan for `extended.gpx` at 8:20/km, fatigue 0.002, 1 h at each LifeBase, with fueling: 60 g carbs, 500 ml, 400 mg sodium per hour, 30 min reserve, full refills at the Start and both LifeBases |

`src/fixtures_test.zig` checks each step: the original's waypoints; that `extended.gpx` is
byte for byte what `waypoints_replace` makes of the original with its checkpoints; and that
`plan.json` is byte for byte what gpxz builds from `extended.gpx` today.

The checkpoints and cutoffs are those of `../grp-160-2026.gpx` (the same instants, which were
written in UTC there). Like a real Waymark export, `extended.gpx` adds no `<metadata><name>`:
the plan's course name is null, and apps fall back to the file name.

## When gpxz's model changes

The plan test fails: the times moved. Rebuild `plan.json` with the same model and fueling (a
short program calling `gpxz.parse`, `fueling.times_from_entries`, `fueling.carry_compute`,
`plan_build` and `plan_write`, as the test does), check the diff is only times and carries,
and update the gpxz version above.
