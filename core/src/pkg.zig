// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! PS4 pkg header: offsets and decoding only. Entry table and PFS image come later.
//! Field offsets were confirmed against the two fixtures in test-rom/ (handoff §6).

const std = @import("std");

pub const header_size: usize = 0x1000;
pub const magic = [4]u8{ 0x7f, 'C', 'N', 'T' };

pub const content_id_offset: usize = 0x40;
pub const content_id_len: usize = 0x24;
pub const file_count_offset: usize = 0x0C;
pub const entry_count_offset: usize = 0x10;
pub const table_offset_offset: usize = 0x18;
pub const body_offset_offset: usize = 0x20;
pub const body_size_offset: usize = 0x28;
pub const pfs_image_count_offset: usize = 0x400;
pub const pfs_image_offset_offset: usize = 0x410;
pub const pfs_image_size_offset: usize = 0x418;
pub const mount_image_size_offset: usize = 0x428;
pub const package_size_offset: usize = 0x430;
pub const split_size_0_offset: usize = 0x480;
pub const split_size_1_offset: usize = 0x488;

pub const Header = struct {
    content_id: [content_id_len]u8,
    file_count: u32,
    entry_count: u32,
    table_offset: u32,
    body_offset: u64,
    body_size: u64,
    pfs_image_count: u32,
    pfs_image_offset: u64,
    pfs_image_size: u64,
    mount_image_size: u64,
    package_size: u64,
    split_sizes: [2]u64,
};

pub const Reason = enum {
    too_short,
    bad_magic,
    image_out_of_range,
};

pub const Failure = struct {
    reason: Reason,
    offset: usize,
};

pub const Result = union(enum) {
    ok: Header,
    fail: Failure,
};

pub fn reasonName(reason: Reason) []const u8 {
    return switch (reason) {
        .too_short => "file shorter than the 0x1000 byte header",
        .bad_magic => "not a pkg: expected magic 7F 43 4E 54",
        .image_out_of_range => "pfs image extends past the end of the file, likely truncated",
    };
}

/// `bytes` may be shorter than the file, but must contain the whole header.
/// `file_size` is the real size, used for the truncation check.
pub fn parseHeader(bytes: []const u8, file_size: u64) Result {
    if (bytes.len < header_size) {
        return .{ .fail = .{ .reason = .too_short, .offset = bytes.len } };
    }
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) {
        return .{ .fail = .{ .reason = .bad_magic, .offset = 0 } };
    }

    const header: Header = .{
        .content_id = bytes[content_id_offset..][0..content_id_len].*,
        .file_count = readU32(bytes, file_count_offset),
        .entry_count = readU32(bytes, entry_count_offset),
        .table_offset = readU32(bytes, table_offset_offset),
        .body_offset = readU64(bytes, body_offset_offset),
        .body_size = readU64(bytes, body_size_offset),
        .pfs_image_count = readU32(bytes, pfs_image_count_offset),
        .pfs_image_offset = readU64(bytes, pfs_image_offset_offset),
        .pfs_image_size = readU64(bytes, pfs_image_size_offset),
        .mount_image_size = readU64(bytes, mount_image_size_offset),
        .package_size = readU64(bytes, package_size_offset),
        .split_sizes = .{
            readU64(bytes, split_size_0_offset),
            readU64(bytes, split_size_1_offset),
        },
    };

    // Overflow means the values are nonsense, not a huge pkg.
    const image_end = std.math.add(u64, header.pfs_image_offset, header.pfs_image_size) catch {
        return .{ .fail = .{ .reason = .image_out_of_range, .offset = pfs_image_size_offset } };
    };
    if (image_end > file_size) {
        return .{ .fail = .{ .reason = .image_out_of_range, .offset = pfs_image_size_offset } };
    }

    return .{ .ok = header };
}

/// Use only after parseHeader returned .ok; the header bounds are already checked.
fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .big);
}

fn testHeader(alloc_bytes: *[header_size]u8) []u8 {
    @memset(alloc_bytes, 0);
    @memcpy(alloc_bytes[0..magic.len], &magic);
    @memcpy(alloc_bytes[content_id_offset..][0..content_id_len], "UP4040-CUSA00740_00-TERRARIA00000001");
    std.mem.writeInt(u32, alloc_bytes[file_count_offset..][0..4], 15, .big);
    std.mem.writeInt(u32, alloc_bytes[entry_count_offset..][0..4], 32, .big);
    std.mem.writeInt(u32, alloc_bytes[table_offset_offset..][0..4], 0x2a80, .big);
    std.mem.writeInt(u64, alloc_bytes[body_offset_offset..][0..8], 0x2000, .big);
    std.mem.writeInt(u64, alloc_bytes[body_size_offset..][0..8], 0x2fe000, .big);
    std.mem.writeInt(u32, alloc_bytes[pfs_image_count_offset..][0..4], 1, .big);
    std.mem.writeInt(u64, alloc_bytes[pfs_image_offset_offset..][0..8], 0x300000, .big);
    std.mem.writeInt(u64, alloc_bytes[pfs_image_size_offset..][0..8], 0x06130000, .big);
    std.mem.writeInt(u64, alloc_bytes[mount_image_size_offset..][0..8], 0x06430000, .big);
    std.mem.writeInt(u64, alloc_bytes[package_size_offset..][0..8], 0x06430000, .big);
    std.mem.writeInt(u64, alloc_bytes[split_size_0_offset..][0..8], 0x1111, .big);
    std.mem.writeInt(u64, alloc_bytes[split_size_1_offset..][0..8], 0x2222, .big);
    return alloc_bytes;
}

test "parseHeader: reads the base sample header fields" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);

    const header = switch (parseHeader(bytes, 0x06430000)) {
        .ok => |h| h,
        .fail => |f| {
            std.debug.print("unexpected failure: {s}\n", .{reasonName(f.reason)});
            return error.UnexpectedFailure;
        },
    };

    try std.testing.expectEqualStrings("UP4040-CUSA00740_00-TERRARIA00000001", &header.content_id);
    try std.testing.expectEqual(@as(u32, 15), header.file_count);
    try std.testing.expectEqual(@as(u32, 32), header.entry_count);
    try std.testing.expectEqual(@as(u32, 0x2a80), header.table_offset);
    try std.testing.expectEqual(@as(u64, 0x2000), header.body_offset);
    try std.testing.expectEqual(@as(u64, 0x2fe000), header.body_size);
    try std.testing.expectEqual(@as(u32, 1), header.pfs_image_count);
    try std.testing.expectEqual(@as(u64, 0x300000), header.pfs_image_offset);
    try std.testing.expectEqual(@as(u64, 0x06130000), header.pfs_image_size);
    try std.testing.expectEqual(@as(u64, 0x06430000), header.package_size);
    try std.testing.expectEqual(@as(u64, 0x1111), header.split_sizes[0]);
    try std.testing.expectEqual(@as(u64, 0x2222), header.split_sizes[1]);
}

test "parseHeader: image end equals package size on the sample shape" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    const header = switch (parseHeader(bytes, 0x06430000)) {
        .ok => |h| h,
        .fail => return error.UnexpectedFailure,
    };
    try std.testing.expectEqual(header.package_size, header.pfs_image_offset + header.pfs_image_size);
}

test "parseHeader: rejects a file shorter than the header" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    switch (parseHeader(bytes[0..0x800], 0x800)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| {
            try std.testing.expectEqual(Reason.too_short, f.reason);
            try std.testing.expectEqual(@as(usize, 0x800), f.offset);
        },
    }
}

test "parseHeader: rejects a wrong magic" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    bytes[0] = 0x00;
    switch (parseHeader(bytes, 0x06430000)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| try std.testing.expectEqual(Reason.bad_magic, f.reason),
    }
}

test "parseHeader: rejects an image past the end of the file" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    switch (parseHeader(bytes, 0x06430000 - 1)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| {
            try std.testing.expectEqual(Reason.image_out_of_range, f.reason);
            try std.testing.expectEqual(pfs_image_size_offset, f.offset);
        },
    }
}

test "parseHeader: rejects an offset plus size that overflows" {
    var raw: [header_size]u8 = undefined;
    const bytes = testHeader(&raw);
    std.mem.writeInt(u64, bytes[pfs_image_offset_offset..][0..8], std.math.maxInt(u64), .big);
    switch (parseHeader(bytes, 0x06430000)) {
        .ok => return error.ExpectedFailure,
        .fail => |f| try std.testing.expectEqual(Reason.image_out_of_range, f.reason),
    }
}
