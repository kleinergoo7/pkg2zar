// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Reads only what is needed to name an output: header, entry table, and sce_sys/param.sfo.
//! No decryption, so this works even on pkgs the converter would refuse.

const std = @import("std");
const pkg = @import("pkg.zig");
const psf = @import("psf.zig");

pub const Info = struct {
    title: ?[]const u8 = null,
    title_id: ?[]const u8 = null,
    version: ?[]const u8 = null,
    is_patch: bool = false,
};

pub const Error = error{
    CannotOpen,
    TooShort,
    BadHeader,
    BadEntryTable,
    MissingParamSfo,
    BadParamSfo,
    OutOfMemory,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.CannotOpen => "cannot open the pkg",
        error.TooShort => "file is shorter than the pkg header",
        error.BadHeader => "pkg header is not readable",
        error.BadEntryTable => "pkg entry table is outside the file",
        error.MissingParamSfo => "pkg has no sce_sys/param.sfo entry",
        error.BadParamSfo => "param.sfo is malformed",
        error.OutOfMemory => "out of memory",
    };
}

pub fn run(io: std.Io, arena: std.mem.Allocator, path: []const u8) Error!Info {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.CannotOpen;
    defer file.close(io);
    const file_size = file.length(io) catch return error.CannotOpen;

    var raw: [pkg.header_size]u8 = undefined;
    const want: usize = @intCast(@min(file_size, raw.len)); // bounded by the buffer
    _ = file.readPositionalAll(io, raw[0..want], 0) catch return error.CannotOpen;
    const header = switch (pkg.parseHeader(raw[0..want], file_size)) {
        .ok => |h| h,
        .fail => |failure| return switch (failure.reason) {
            .too_short => error.TooShort,
            .bad_magic => error.BadHeader,
            .image_out_of_range => error.BadHeader,
        },
    };

    const table_len = @as(u64, header.entry_count) * pkg.entry_size;
    const table_end = std.math.add(u64, header.table_offset, table_len) catch return error.BadEntryTable;
    if (table_end > file_size) return error.BadEntryTable;
    const table = arena.alloc(u8, @intCast(table_len)) catch return error.OutOfMemory;
    _ = file.readPositionalAll(io, table, header.table_offset) catch return error.BadEntryTable;
    const entries = arena.alloc(pkg.Entry, header.entry_count) catch return error.OutOfMemory;
    pkg.parseEntries(table, 0, entries) catch return error.BadEntryTable;

    var info: Info = .{
        .title_id = titleId(&header),
        .is_patch = pkg.isPatch(header.content_flags),
    };

    var param: ?pkg.Entry = null;
    for (entries) |entry| {
        if (entry.id == pkg.entry_id_param_sfo) {
            param = entry;
            break;
        }
    }
    const sfo_entry = param orelse return info; // header-only info is still useful
    if (@as(u64, sfo_entry.offset) + sfo_entry.size > file_size) return error.BadEntryTable;
    const sfo = arena.alloc(u8, sfo_entry.size) catch return error.OutOfMemory;
    _ = file.readPositionalAll(io, sfo, sfo_entry.offset) catch return error.BadEntryTable;

    info.title = psf.findString(sfo, "TITLE") catch return error.BadParamSfo;
    info.version = psf.findString(sfo, "APP_VER") catch return error.BadParamSfo;
    return info;
}

fn titleId(header: *const pkg.Header) ?[]const u8 {
    const id = std.mem.trimEnd(u8, &header.content_id, "\x00 ");
    if (id.len < 16 or id[6] != '-') return null;
    return id[7..16];
}

test "integration: probe reads the real title, id and version" {
    const path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const info = try run(std.testing.io, arena_state.allocator(), path);
    try std.testing.expectEqualStrings("Terraria", info.title.?);
    try std.testing.expectEqualStrings("CUSA00740", info.title_id.?);
    try std.testing.expect(info.version != null);
    try std.testing.expect(!info.is_patch);
    std.debug.print("probe: title={s} id={s} version={s}\n", .{ info.title.?, info.title_id.?, info.version.? });
}
