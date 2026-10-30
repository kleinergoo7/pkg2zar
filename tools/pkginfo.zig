// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const p2z = @import("p2z");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next();
    const path = args.next() orelse {
        std.process.fatal("usage: pkginfo <file.pkg>", .{});
    };
    if (args.next() != null) {
        std.process.fatal("usage: pkginfo <file.pkg>", .{});
    }

    const io = init.io;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.process.fatal("{s}: cannot open: {t}", .{ path, err });
    };
    defer file.close(io);

    const file_size = file.length(io) catch |err| {
        std.process.fatal("{s}: cannot stat: {t}", .{ path, err });
    };

    var raw: [p2z.pkg.header_size]u8 = undefined;
    const want: usize = @intCast(@min(file_size, raw.len)); // bounded by the 0x1000 buffer
    const got = file.readPositionalAll(io, raw[0..want], 0) catch |err| {
        std.process.fatal("{s}: cannot read header: {t}", .{ path, err });
    };

    const header = switch (p2z.pkg.parseHeader(raw[0..got], file_size)) {
        .ok => |h| h,
        .fail => |f| std.process.fatal("{s}: {s} (at 0x{X})", .{ path, p2z.pkg.reasonName(f.reason), f.offset }),
    };

    var storage: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    try w.print("{s}\n", .{path});
    try w.print("  content id       {s}\n", .{std.mem.trimEnd(u8, &header.content_id, "\x00 ")});
    try w.print("  file count       {d}\n", .{header.file_count});
    try w.print("  entry count      {d}\n", .{header.entry_count});
    try w.print("  table offset     0x{X}\n", .{header.table_offset});
    try w.print("  body             0x{X} + 0x{X}\n", .{ header.body_offset, header.body_size });
    try w.print("  pfs image count  {d}\n", .{header.pfs_image_count});
    try w.print("  pfs image        0x{X} + 0x{X}\n", .{ header.pfs_image_offset, header.pfs_image_size });
    try w.print("  mount image size 0x{X}\n", .{header.mount_image_size});
    try w.print("  package size     0x{X}\n", .{header.package_size});
    try w.print("  split sizes      0x{X} 0x{X}\n", .{ header.split_sizes[0], header.split_sizes[1] });
    try w.print("  file size        0x{X}\n", .{file_size});

    const image_end = header.pfs_image_offset + header.pfs_image_size;
    if (image_end != header.package_size or header.package_size != file_size) {
        std.process.fatal(
            "{s}: header inconsistent: image end 0x{X}, package size 0x{X}, file size 0x{X}",
            .{ path, image_end, header.package_size, file_size },
        );
    }
    try w.print("  invariant        ok (image end == package size == file size)\n", .{});

    try std.Io.File.stdout().writeStreamingAll(io, storage[0..w.end]);
}
