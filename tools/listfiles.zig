// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Lists the files a pkg contains. Reads only the pkg header, the entry table, and the
//! metadata blocks of the PFS image; file data blocks are untouched.

const std = @import("std");
const p2z = @import("p2z");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next();
    const path = args.next() orelse std.process.fatal("usage: listfiles <file.pkg>", .{});
    if (args.next() != null) std.process.fatal("usage: listfiles <file.pkg>", .{});

    const io = init.io;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err|
        std.process.fatal("{s}: cannot open: {t}", .{ path, err });
    defer file.close(io);

    const file_size = file.length(io) catch |err|
        std.process.fatal("{s}: cannot stat: {t}", .{ path, err });

    var raw: [p2z.pkg.header_size]u8 = undefined;
    const want: usize = @intCast(@min(file_size, raw.len)); // bounded by the 0x1000 buffer
    const got = file.readPositionalAll(io, raw[0..want], 0) catch |err|
        std.process.fatal("{s}: cannot read header: {t}", .{ path, err });

    const header = switch (p2z.pkg.parseHeader(raw[0..got], file_size)) {
        .ok => |h| h,
        .fail => |f| std.process.fatal("{s}: {s} (at 0x{X})", .{ path, p2z.pkg.reasonName(f.reason), f.offset }),
    };
    if (p2z.pkg.isDeltaPatch(header.content_flags)) {
        std.process.fatal("{s}: delta update, not supported", .{path});
    }

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try arena.alloc(p2z.pkg.Entry, header.entry_count);
    const table_len = @as(u64, header.entry_count) * p2z.pkg.entry_size;
    if (header.table_offset + table_len > file_size) {
        std.process.fatal("{s}: entry table at 0x{X} runs past the end of the file", .{ path, header.table_offset });
    }
    const table = try arena.alloc(u8, @intCast(table_len));
    if (try file.readPositionalAll(io, table, header.table_offset) != table.len) {
        std.process.fatal("{s}: short read of the entry table", .{path});
    }
    p2z.pkg.parseEntries(table, 0, entries) catch
        std.process.fatal("{s}: entry table at 0x{X} is malformed", .{ path, header.table_offset });

    const keys = p2z.unpack.derive(io, file, file_size, header, entries) catch |err|
        std.process.fatal("{s}: {s}", .{ path, p2z.unpack.reasonName(err) });

    // The reference implementation reads pfs_cache_size * 2 bytes of the image and finds the
    // PFSC table inside that window.
    const window_len: u64 = @as(u64, header.pfs_cache_size) * 2;
    const available = file_size - header.pfs_image_offset;
    const take: usize = @intCast(@min(window_len, available));
    const encrypted = try arena.alloc(u8, take);
    const read_n = try file.readPositionalAll(io, encrypted, header.pfs_image_offset);
    if (read_n != take) std.process.fatal("{s}: short read of the PFS image", .{path});

    const plain = try arena.alloc(u8, take);
    var sector: u64 = 0;
    var off: usize = 0;
    while (off < take) : (off += 0x1000) {
        const end = @min(off + 0x1000, take);
        p2z.crypto.xtsDecrypt(keys.data, keys.tweak, sector, encrypted[off..end], plain[off..end]);
        sector += 1;
    }

    const walk = p2z.pfs.walk(arena, plain) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| std.process.fatal("{s}: {s}", .{ path, p2z.pfs.reasonName(e) }),
    };

    var storage: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var file_count: usize = 0;
    var dir_count: usize = 0;
    for (walk.entries) |entry| {
        switch (entry.kind) {
            .dir => dir_count += 1,
            .file => file_count += 1,
        }
        try w.print("{s} {s}\n", .{ @tagName(entry.kind), entry.path });
    }
    try w.print("-- {d} files, {d} dirs, inode count {d}\n", .{ file_count, dir_count, walk.inodes.len });
    try std.Io.File.stdout().writeStreamingAll(io, storage[0..w.end]);
}
