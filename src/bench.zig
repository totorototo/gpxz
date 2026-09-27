//! Benchmarks, run with `zig build bench`. They print timings and assert nothing about time,
//! so they live here and not in the tests: a slow machine must not fail `zig build test`.
//! build.zig always compiles this in ReleaseFast, because Debug timings say nothing.

const std = @import("std");
const assert = std.debug.assert;
const gpxz = @import("gpxz");

/// Each case runs this many times and reports the fastest run: the minimum is the run least
/// disturbed by the rest of the machine.
const runs = 5;

/// Douglas-Peucker is O(n·depth) on a path like this one. An accidental O(n²) would show up
/// as the 100K time growing 100× from the 10K one instead of about 10×.
const synthetic_point_counts = [_]u32{ 10_000, 50_000, 100_000 };

/// The same tolerance trace.zig simplifies with.
const epsilon_m = 2.0;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    for (synthetic_point_counts) |count| {
        const points = try synthetic_trace(allocator, count);
        defer allocator.free(points);
        try simplify_bench(allocator, io, writer, points, "synthetic switchbacks");
    }

    // A real route: the 160 km fixture, the largest file in testdata/.
    const bytes = @embedFile("grp-160-2026.gpx");
    var elapsed_ns_min: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var data = try gpxz.parse(allocator, bytes, &.{});
        const elapsed_ns = start.untilNow(io).raw.nanoseconds;
        data.deinit(allocator);
        elapsed_ns_min = @min(elapsed_ns_min, elapsed_ns);
    }
    assert(elapsed_ns_min >= 0);
    try writer.print("parse                      grp-160-2026.gpx ({d} KiB)  {d:>6} ms\n", .{
        bytes.len / 1024,
        milliseconds(elapsed_ns_min),
    });
    try writer.flush();
}

fn simplify_bench(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    points: []const [3]f64,
    label: []const u8,
) !void {
    assert(points.len > 2);
    var elapsed_ns_min: i96 = std.math.maxInt(i96);
    var kept: usize = 0;
    for (0..runs) |_| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const indices = try gpxz.simplify.douglas_peucker_indices(allocator, points, epsilon_m);
        const elapsed_ns = start.untilNow(io).raw.nanoseconds;
        kept = indices.len;
        allocator.free(indices);
        elapsed_ns_min = @min(elapsed_ns_min, elapsed_ns);
    }
    assert(kept >= 2 and kept <= points.len);
    assert(elapsed_ns_min >= 0);
    try writer.print("douglas_peucker_indices    {s}, {d:>6} → {d:>5} points  {d:>6} ms\n", .{
        label,
        points.len,
        kept,
        milliseconds(elapsed_ns_min),
    });
}

fn milliseconds(elapsed_ns: i96) u64 {
    assert(elapsed_ns >= 0);
    return @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
}

/// Returns a mountain-trail path heading north-east with sinusoidal switchbacks and a rising,
/// undulating profile: neither a straight line (trivially fast) nor an adversarial zigzag.
/// The caller owns the returned slice.
fn synthetic_trace(allocator: std.mem.Allocator, count: u32) ![][3]f64 {
    assert(count > 2);
    const points = try allocator.alloc([3]f64, count);
    for (points, 0..) |*point, index| {
        const t = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count));
        const latitude = 45.0 + t * 0.5;
        const longitude = -122.0 + t * 0.3 + @sin(t * std.math.pi * 30.0) * 0.002;
        const elevation_m = 500.0 + t * 1500.0 + @sin(t * std.math.pi * 60.0) * 100.0;
        point.* = .{ latitude, longitude, elevation_m };
    }
    assert(points.len == count);
    return points;
}
