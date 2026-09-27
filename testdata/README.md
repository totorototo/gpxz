# Test fixtures

Real GPX files, written by tools other than gpxz. `src/fixtures_test.zig` embeds them, so
`zig build test` runs against them. Each file is listed in `build.zig` (`fixtures`), because
`@embedFile` can't reach outside `src/` by path.

All files are the 2026 course routes of the Grand Raid des Pyrénées, exported from
trail-passion.net (the `<metadata><link>` in each file gives the trace id) with the race's
checkpoints and cutoff times as typed waypoints. The expected values in the tests come from
outside gpxz: counts from the file text, epochs converted with Python, and the distance
trail-passion.net printed in the link text.

| File | Race | What it checks |
|---|---|---|
| `grp-40-gela-2026.gpx` | Tour de la Gela, 41.6 km | A loop: same start and end elevation |
| `grp-40-neouvielle-2026.gpx` | Tour du Néouvielle, 43.1 km | The fewest waypoints: 2 TimeBarriers |
| `grp-50-2026.gpx` | Tour du Bastan, 53.3 km | Point to point: D+ − D- matches an 860 m net descent |
| `grp-60-2026.gpx` | Tour du Moudang, 60.8 km | Point to point: 1070 m net descent |
| `grp-80-2026.gpx` | Tour des Lacs, 80.5 km | Arrival cutoff on the next day |
| `grp-120-2026.gpx` | Tour des Cirques, 125.8 km | One LifeBase, so two stages |
| `grp-160-2026.gpx` | Ultra Tour, 174.7 km | The largest file (30899 points, 3 MB); two LifeBases, three stages |

Don't add GPX files you recorded yourself: they hold your GPS tracks. `.gitignore` ignores
`*.gpx` everywhere except here.
