//! gpxz: GPX parsing and trail computations (distances, D+/D-, climbs, sections, stages,
//! pace model). Pure: every function works on in-memory bytes and slices, and does no I/O.

const std = @import("std");

pub const gpx = @import("gpx.zig");
pub const gpx_data = @import("gpx_data.zig");
pub const trace = @import("trace.zig");
pub const gps_point = @import("gps_point.zig");
pub const time = @import("time.zig");
pub const simplify = @import("simplify.zig");
pub const extrema = @import("extrema.zig");
pub const climbs = @import("climbs.zig");
pub const elevation = @import("elevation.zig");
pub const leg = @import("leg.zig");
pub const section = @import("section.zig");
pub const stage = @import("stage.zig");
pub const calibration = @import("calibration.zig");
pub const segment = @import("segment.zig");
pub const minetti = @import("minetti.zig");
pub const pace_model = @import("pace_model.zig");
pub const soundscape = @import("soundscape.zig");

pub const GPXData = gpx_data.GPXData;
pub const Waypoint = gpx_data.Waypoint;
pub const Metadata = gpx_data.Metadata;
pub const Trace = trace.Trace;
pub const ClimbStats = climbs.ClimbStats;
pub const DescentStats = climbs.DescentStats;
pub const LegStats = leg.LegStats;
pub const SectionStats = section.SectionStats;
pub const StageStats = stage.StageStats;
pub const PlanEntry = calibration.PlanEntry;
pub const WeatherLookup = pace_model.WeatherLookup;
pub const Settings = pace_model.Settings;
pub const ParseError = gpx.ParseError;
pub const parse = gpx.parse;

test {
    std.testing.refAllDecls(@This());
}
