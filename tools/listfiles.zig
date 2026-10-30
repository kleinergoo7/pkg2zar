// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Lists the files a pkg contains. Accepts several paths as one piece set.

const std = @import("std");
const p2z = @import("p2z");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    var paths: [64][]const u8 = undefined;
    var count: usize = 0;
    while (args.next()) |arg| {
        if (count == paths.len) std.process.fatal("too many inputs", .{});
        paths[count] = arg;
        count += 1;
    }
    if (count == 0) std.process.fatal("usage: listfiles <file.pkg> [piece.pkg ...]", .{});

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try p2z.source.Source.open(init.io, arena, paths[0..count]);
    const src = switch (result) {
        .ok => |s| s,
        .fail => |fail| {
            var buf: [512]u8 = undefined;
            std.process.fatal("{s}", .{p2z.source.describe(fail, &buf)});
        },
    };
    defer src.close();

    var file_count: usize = 0;
    var dir_count: usize = 0;
    var line: [1024]u8 = undefined;
    const stdout = std.Io.File.stdout();
    for (src.walk.entries) |entry| {
        switch (entry.kind) {
            .file => file_count += 1,
            .dir => dir_count += 1,
        }
        const text = try std.fmt.bufPrint(&line, "{s} {s}\n", .{ @tagName(entry.kind), entry.path });
        try stdout.writeStreamingAll(init.io, text);
    }
    const summary = try std.fmt.bufPrint(&line, "-- pfs: {d} files, {d} dirs, {d} inodes\n", .{ file_count, dir_count, src.walk.inodes.len });
    try stdout.writeStreamingAll(init.io, summary);

    const sce = try src.sceFiles();
    for (sce) |file| {
        const text = try std.fmt.bufPrint(&line, "pkg_entry {s} ({d} bytes)\n", .{ file.path, file.entry.size });
        try stdout.writeStreamingAll(init.io, text);
    }
    const sce_summary = try std.fmt.bufPrint(&line, "-- sce_sys entries: {d}\n", .{sce.len});
    try stdout.writeStreamingAll(init.io, sce_summary);
}
