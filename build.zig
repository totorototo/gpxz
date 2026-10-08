const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The module other packages import with `b.dependency("gpxz", ...).module("gpxz")`.
    const gpxz_mod = b.addModule("gpxz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "gpxz",
        .root_module = gpxz_mod,
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "gpxz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gpxz", .module = gpxz_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the gpxz CLI (pass a .gpx path with -- <path>)");
    run_step.dependOn(&run_cmd.step);

    // Library tests start at root.zig, which references every module, so each file's tests
    // run. CLI tests run against main.zig.
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = gpxz_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Timings get their own step so `zig build test` stays fast and can't fail on a slow
    // machine. The bench always builds in ReleaseFast, whatever -Doptimize says: Debug timings
    // say nothing. So it gets its own gpxz module at that mode too.
    const bench_gpxz_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "gpxz", .module = bench_gpxz_mod },
        },
    });
    bench_module.addAnonymousImport("grp-160-2026.gpx", .{
        .root_source_file = b.path("testdata/grp-160-2026.gpx"),
    });
    const bench = b.addExecutable(.{ .name = "gpxz-bench", .root_module = bench_module });
    const bench_step = b.step("bench", "Time Douglas-Peucker and a full parse (ReleaseFast)");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // Tests against real files get their own module, so the fixtures are embedded only there
    // and never in the library module that other packages import. @embedFile can't reach
    // outside src/, so each file is named here and embedded by that name.
    const fixtures_module = b.createModule(.{
        .root_source_file = b.path("src/fixtures_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gpxz", .module = gpxz_mod },
        },
    });
    for (fixtures) |fixture| {
        fixtures_module.addAnonymousImport(fixture, .{
            .root_source_file = b.path(b.fmt("testdata/{s}", .{fixture})),
        });
    }
    const fixtures_tests = b.addTest(.{ .root_module = fixtures_module });
    test_step.dependOn(&b.addRunArtifact(fixtures_tests).step);
}

/// Files in testdata/ that src/fixtures_test.zig embeds. See testdata/README.md.
const fixtures = [_][]const u8{
    "grp-120-2026.gpx",
    "grp-160-2026.gpx",
    "grp-40-gela-2026.gpx",
    "grp-40-neouvielle-2026.gpx",
    "grp-50-2026.gpx",
    "grp-60-2026.gpx",
    "grp-80-2026.gpx",
};
