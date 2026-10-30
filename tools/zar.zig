// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Lists or extracts a `.zar` archive, so a written archive can be checked without a pkg.
//! `list` prints the tree, `extract` writes it to a folder and refuses to overwrite files.

const std = @import("std");
const p2z = @import("p2z");

const usage =
    \\usage: zar list <file.zar>
    \\       zar extract <outdir> <file.zar>
    \\
;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const command = args.next() orelse std.process.fatal("{s}", .{usage});
    if (std.mem.eql(u8, command, "list")) return list(init, &args);
    if (std.mem.eql(u8, command, "extract")) return extract(init, &args);
    std.process.fatal("unknown command '{s}'\n{s}", .{ command, usage });
}

fn open(init: std.process.Init, arena: std.mem.Allocator, path: []const u8) !p2z.zar.Reader {
    const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |err|
        std.process.fatal("{s}: cannot open: {t}", .{ path, err });
    return p2z.zar.Reader.open(init.io, file, arena) catch |err|
        std.process.fatal("{s}: not a readable .zar archive: {t}", .{ path, err });
}

fn list(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const path = args.next() orelse std.process.fatal("usage: zar list <file.zar>", .{});
    if (args.next() != null) std.process.fatal("usage: zar list <file.zar>", .{});

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reader = try open(init, arena, path);
    const entries = reader.entries() catch |err|
        std.process.fatal("{s}: cannot read the archive tree: {t}", .{ path, err });

    var files: usize = 0;
    var dirs: usize = 0;
    var bytes: u64 = 0;
    var line: [4096]u8 = undefined;
    const stdout = std.Io.File.stdout();
    for (entries) |entry| {
        const text = if (entry.is_file) blk: {
            files += 1;
            bytes += entry.size;
            break :blk try std.fmt.bufPrint(&line, "file {s} ({d} bytes)\n", .{ entry.path, entry.size });
        } else blk: {
            dirs += 1;
            break :blk try std.fmt.bufPrint(&line, "dir  {s}\n", .{entry.path});
        };
        try stdout.writeStreamingAll(init.io, text);
    }

    const summary = try std.fmt.bufPrint(&line, "-- zar: {d} files, {d} dirs, {d} bytes\n", .{ files, dirs, bytes });
    try stdout.writeStreamingAll(init.io, summary);
}

fn extract(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const outdir = args.next() orelse std.process.fatal("usage: zar extract <outdir> <file.zar>", .{});
    const path = args.next() orelse std.process.fatal("usage: zar extract <outdir> <file.zar>", .{});
    if (args.next() != null) std.process.fatal("usage: zar extract <outdir> <file.zar>", .{});

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reader = try open(init, arena, path);
    const entries = reader.entries() catch |err|
        std.process.fatal("{s}: cannot read the archive tree: {t}", .{ path, err });

    std.Io.Dir.cwd().createDirPath(init.io, outdir) catch |err|
        std.process.fatal("{s}: cannot create the output directory: {t}", .{ outdir, err });

    var files: usize = 0;
    var dirs: usize = 0;
    var bytes: u64 = 0;
    for (entries) |entry| {
        const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ outdir, entry.path });
        if (!entry.is_file) {
            std.Io.Dir.cwd().createDirPath(init.io, target) catch |err|
                std.process.fatal("{s}: cannot create the directory: {t}", .{ target, err });
            dirs += 1;
            continue;
        }

        if (std.fs.path.dirname(target)) |parent| {
            std.Io.Dir.cwd().createDirPath(init.io, parent) catch |err|
                std.process.fatal("{s}: cannot create the parent directory: {t}", .{ parent, err });
        }
        // Extraction must never destroy a file the archive did not create.
        if (std.Io.Dir.cwd().access(init.io, target, .{})) |_| {
            std.process.fatal("{s}: already exists, remove it or extract elsewhere", .{target});
        } else |_| {}

        const file = std.Io.Dir.cwd().createFile(init.io, target, .{}) catch |err|
            std.process.fatal("{s}: cannot create the file: {t}", .{ target, err });
        defer file.close(init.io);
        reader.copyFile(entry, file) catch |err|
            std.process.fatal("{s}: cannot write the entry: {t}", .{ target, err });
        files += 1;
        bytes += entry.size;
    }

    var line: [4096]u8 = undefined;
    const summary = try std.fmt.bufPrint(&line, "extracted {s}: {d} files, {d} dirs, {d} bytes\n", .{ outdir, files, dirs, bytes });
    try std.Io.File.stdout().writeStreamingAll(init.io, summary);
}
