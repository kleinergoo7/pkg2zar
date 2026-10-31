// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Converts or merges pkgs into a .zar. Progress goes to stderr; the archive only appears
//! under its final name after it verifies.

const std = @import("std");
const p2z = @import("p2z");

var cancelled = std.atomic.Value(bool).init(false);
var last_percent: u64 = 255;

fn onProgress(_: ?*anyopaque, progress: p2z.exporter.Progress) void {
    const percent = if (progress.total == 0) 0 else progress.done * 100 / progress.total;
    if (percent == last_percent) return;
    last_percent = percent;
    std.debug.print("\r{d}% {d}/{d} bytes  {s}\n", .{ percent, progress.done, progress.total, progress.current });
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const output = args.next() orelse std.process.fatal(
        "usage: export <out.zar> <base.pkg> [update.pkg]\n" ++
            "       export <out.zar> <folder> [update-folder]",
        .{},
    );
    var paths: [2][]const u8 = undefined;
    var count: usize = 0;
    while (args.next()) |arg| {
        if (count == 2) std.process.fatal("usage: export <out.zar> <base.pkg> [update.pkg]", .{});
        paths[count] = arg;
        count += 1;
    }
    if (count == 0) std.process.fatal("usage: export <out.zar> <base.pkg> [update.pkg]", .{});

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Directories are extracted trees, not pkgs. A mix of the two cannot be merged, and the
    // pkg path below produces its own precise message when a path is not a pkg.
    var directories: usize = 0;
    for (paths[0..count]) |path| {
        if (std.Io.Dir.cwd().openDir(init.io, path, .{})) |dir| {
            dir.close(init.io);
            directories += 1;
        } else |_| {}
    }
    if (directories == count) return exportFolders(init, arena, paths[0..count], output);
    if (directories > 0) std.process.fatal("do not mix pkgs and folders: {s}", .{paths[0]});

    var sources: [2]p2z.source.Source = undefined;
    var opened: usize = 0;
    defer for (sources[0..opened]) |s| s.close();
    for (paths[0..count], 0..) |path, i| {
        switch (try p2z.source.Source.open(init.io, arena, &.{path})) {
            .ok => |src| {
                sources[i] = src;
                opened += 1;
            },
            .fail => |fail| {
                var buf: [512]u8 = undefined;
                std.process.fatal("{s}", .{p2z.source.describe(fail, &buf)});
            },
        }
    }

    var base_identity = p2z.plan.Identity.fromSource(&sources[0]);
    var update_identity = if (count == 2) p2z.plan.Identity.fromSource(&sources[1]) else null;
    if (update_identity) |upd| {
        if (p2z.plan.shouldSwapRoles(base_identity, upd)) {
            std.mem.swap(p2z.source.Source, &sources[0], &sources[1]);
            base_identity = upd;
            update_identity = p2z.plan.Identity.fromSource(&sources[1]);
            std.debug.print("note: inputs were swapped, the update was listed first\n", .{});
        }
    }
    if (p2z.plan.preflight(base_identity, update_identity)) |failure| {
        var buf: [512]u8 = undefined;
        std.process.fatal("{s}", .{p2z.plan.describe(failure, &buf)});
    }

    const plan = try p2z.plan.build(arena, sources[0..count]);
    const stats = p2z.exporter.run(arena, init.io, sources[0..count], &plan, .{
        .output = output,
        .cancel = &cancelled,
        .on_progress = onProgress,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| std.process.fatal("{s}", .{p2z.exporter.reasonName(e)}),
    };

    std.debug.print("\r", .{});
    std.debug.print("wrote {s}: {d} files, {d} dirs, {d} bytes\n", .{ output, stats.files, stats.dirs, stats.bytes });
}

fn exportFolders(
    init: std.process.Init,
    arena: std.mem.Allocator,
    paths: []const []const u8,
    output: []const u8,
) !void {
    var ordered: [2][]const u8 = undefined;
    var roots: []const []const u8 = paths;
    if (paths.len == 2) {
        const first = p2z.probe.runFolder(init.io, arena, paths[0]) catch |err|
            std.process.fatal("{s}: {s}", .{ paths[0], p2z.probe.reasonName(err) });
        const second = p2z.probe.runFolder(init.io, arena, paths[1]) catch |err|
            std.process.fatal("{s}: {s}", .{ paths[1], p2z.probe.reasonName(err) });
        switch (p2z.probe.folderRole(first, second)) {
            .ok => |pair| {
                ordered[0] = paths[pair.base];
                ordered[1] = paths[pair.update];
                roots = ordered[0..2];
            },
            .missing_title_id => |f| std.process.fatal(
                "{s}: no title id in sce_sys/param.sfo, cannot tell base from update",
                .{f.path},
            ),
            .title_mismatch => |f| std.process.fatal(
                "title ids differ: {s} and {s}; these are not a base and its update",
                .{ f.first, f.second },
            ),
            .missing_version => |f| std.process.fatal(
                "{s}: no APP_VER in sce_sys/param.sfo, cannot tell base from update",
                .{f.path},
            ),
            .same_version => |f| std.process.fatal(
                "cannot tell base from update: both are v{s}",
                .{f.version},
            ),
            .version_unreadable => |f| std.process.fatal(
                "{s}: APP_VER '{s}' is not numeric",
                .{ f.path, f.version },
            ),
        }
    }

    const stats = p2z.folder.runRoots(arena, init.io, roots, .{
        .output = output,
        .cancel = &cancelled,
        .on_progress = onProgress,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| std.process.fatal("{s}: {s}", .{ roots[0], p2z.folder.reasonName(e) }),
    };

    std.debug.print("\r", .{});
    std.debug.print("wrote {s}: {d} files, {d} dirs, {d} bytes\n", .{ output, stats.files, stats.dirs, stats.bytes });
}
