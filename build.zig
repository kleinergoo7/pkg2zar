// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

const tools = [_][]const u8{ "pkginfo", "listfiles", "plan", "export", "extract" };

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

    inline for (tools) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "p2z", .module = core }},
            }),
        });
        b.installArtifact(exe);
    }

    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const ui = b.addExecutable(.{
        .name = "ps4-pkg2zar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui.module("dvui_sdl3") },
                .{ .name = "p2z", .module = core },
            },
        }),
    });
    ui.root_module.linkSystemLibrary("zstd", .{});
    b.installArtifact(ui);

    const run = b.addRunArtifact(ui);
    run.addPassthruArgs();
    b.step("run", "Run the application").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
