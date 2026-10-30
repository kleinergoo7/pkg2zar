// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zon = @import("build.zig.zon");

const tools = [_][]const u8{ "pkginfo", "listfiles", "plan", "export", "extract", "zar" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // zstd comes from a Zig package: Windows and macOS CI have no system libzstd.
    const zstd = b.dependency("zstd", .{ .target = target, .optimize = optimize });
    core.linkLibrary(zstd.artifact("zstd"));

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

    // SDL3 everywhere except Windows: its SDL package carries ALSA sample files with ':' in
    // their names, which NTFS cannot check out. dvui's DX11 backend avoids that dependency.
    const windows = target.result.os.tag == .windows;
    const dvui = if (windows)
        b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .dx11 })
    else
        b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);

    const ui = b.addExecutable(.{
        .name = "ps4-pkg2zar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui.module(if (windows) "dvui_dx11" else "dvui_sdl3") },
                .{ .name = "p2z", .module = core },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(ui);

    const run = b.addRunArtifact(ui);
    run.addPassthruArgs();
    b.step("run", "Run the application").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // zig-pkg/ holds fetched dependencies; formatting them is not our business.
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("core"), b.path("tools"), b.path("ui") },
        .check = true,
    });
    b.step("check", "Check formatting of the Zig sources").dependOn(&fmt.step);
}
