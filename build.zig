// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.linkSystemLibrary("zstd", .{});

    const lib = b.addLibrary(.{
        .name = "p2z_core",
        .linkage = .static,
        .root_module = core,
    });
    b.installArtifact(lib);

    const pkginfo = b.addExecutable(.{
        .name = "pkginfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/pkginfo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "p2z", .module = core }},
        }),
    });
    b.installArtifact(pkginfo);

    const listfiles = b.addExecutable(.{
        .name = "listfiles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/listfiles.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "p2z", .module = core }},
        }),
    });
    b.installArtifact(listfiles);

    const plan_tool = b.addExecutable(.{
        .name = "plan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/plan.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "p2z", .module = core }},
        }),
    });
    b.installArtifact(plan_tool);

    const export_tool = b.addExecutable(.{
        .name = "export",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/export.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "p2z", .module = core }},
        }),
    });
    b.installArtifact(export_tool);

    const tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
