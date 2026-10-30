// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Extracts pkgs into a folder tree; merges when two inputs are given. Progress to stderr.

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

    const output = args.next() orelse std.process.fatal("usage: extract <outdir> <base.pkg> [update.pkg]", .{});
    var paths: [2][]const u8 = undefined;
    var count: usize = 0;
    while (args.next()) |arg| {
        if (count == 2) std.process.fatal("usage: extract <outdir> <base.pkg> [update.pkg]", .{});
        paths[count] = arg;
        count += 1;
    }
    if (count == 0) std.process.fatal("usage: extract <outdir> <base.pkg> [update.pkg]", .{});

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    const stats = p2z.extractor.run(arena, init.io, sources[0..count], &plan, .{
        .output = output,
        .cancel = &cancelled,
        .on_progress = onProgress,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| std.process.fatal("{s}", .{p2z.extractor.reasonName(e)}),
    };

    std.debug.print("\r", .{});
    std.debug.print("extracted {s}: {d} files, {d} dirs, {d} bytes\n", .{ output, stats.files, stats.dirs, stats.bytes });
}
