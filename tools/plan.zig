// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Preflight and merge plan for one or two pkgs. Prints what the archive would contain,
//! changes nothing.

const std = @import("std");
const p2z = @import("p2z");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    var paths: [2][]const u8 = undefined;
    var count: usize = 0;
    var manifest = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--manifest")) {
            manifest = true;
            continue;
        }
        if (count == 2) std.process.fatal("usage: plan [--manifest] <base.pkg> [update.pkg]", .{});
        paths[count] = arg;
        count += 1;
    }
    if (count == 0) std.process.fatal("usage: plan [--manifest] <base.pkg> [update.pkg]", .{});

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources: [2]p2z.source.Source = undefined;
    var opened: usize = 0;
    defer for (sources[0..opened]) |s| s.close();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const result = try p2z.source.Source.open(init.io, arena, paths[i .. i + 1]);
        switch (result) {
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

    var out: std.Io.Writer = .fixed(try arena.alloc(u8, 64 * 1024));

    // Verification manifest: the exact writer call sequence, so a reference writer can be fed
    // the same order for a byte comparison.
    if (manifest) {
        for (plan.items) |item| {
            const tag = switch (item.kind) {
                .pfs_dir => "d",
                .pkg_entry, .pfs_file => "f",
            };
            try out.print("{s} {s}\n", .{ tag, item.path });
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, out.buffer[0..out.end]);
        return;
    }

    try out.print("mode        {s}\n", .{if (count == 2) "merge" else "convert"});
    try out.print("title id    {s}\n", .{base_identity.titleId() orelse "?"});
    try out.print("files       {d}\n", .{plan.file_count});
    try out.print("directories {d}\n", .{plan.dir_count});
    try out.print("bytes       {d}\n", .{plan.total_bytes});
    if (count == 2) try out.print("overrides   {d} (update wins)\n", .{plan.overrides});

    var shown: usize = 0;
    for (plan.items) |item| {
        if (shown == 20) {
            try out.print("... {d} more\n", .{plan.items.len - shown});
            break;
        }
        try out.print("{s} {s}\n", .{ @tagName(item.kind), item.path });
        shown += 1;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, out.buffer[0..out.end]);
}
