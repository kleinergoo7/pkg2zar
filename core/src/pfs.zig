// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! PFSC walk: the compressed filesystem inside the PFS image. Produces the file list only;
//! streaming file data comes later. Ported from shadPS4 pkg.cpp (GPL-2.0-or-later).

const std = @import("std");

pub const pfsc_magic: u32 = 0x43534650; // "PFSC" in little-endian bytes
pub const block_size: usize = 0x10000;
pub const inode_stride: usize = 0xA8;
pub const inode_mode_offset: usize = 0x00;
pub const inode_size_offset: usize = 0x08;
pub const inode_blocks_offset: usize = 0x60;
pub const inode_loc_offset: usize = 0x64;

pub const dirent_type_file: u32 = 2;
pub const dirent_type_dir: u32 = 3;
pub const dirent_type_self: u32 = 4;
pub const dirent_type_parent: u32 = 5;

pub const Error = error{
    OutOfMemory,
    NoPfsc,
    BadPfscHeader,
    BlockOutOfRange,
    InflateFailed,
    MissingInode,
    BadDirent,
};

pub fn reasonName(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.NoPfsc => "no PFSC table found in the PFS image",
        error.BadPfscHeader => "PFSC header is inconsistent",
        error.BlockOutOfRange => "PFSC block offsets point outside the image",
        error.InflateFailed => "PFSC block failed to inflate",
        error.MissingInode => "directory entry refers to a missing inode",
        error.BadDirent => "malformed directory entry",
    };
}

pub const Kind = enum { file, dir };

pub const Entry = struct {
    path: []const u8,
    inode: u32,
    kind: Kind,
    size: u64,
    blocks: u32,
    loc: u32,
};

pub const Inode = struct {
    mode: u16,
    size: u64,
    blocks: u32,
    loc: u32,
};

pub const Walk = struct {
    entries: []Entry,
    inodes: []Inode,
    pfsc_offset: usize,
    /// Raw sector map: block_count + 1 little-endian u64 offsets relative to the PFSC start.
    map: []const u8,
    block_count: usize,

    pub fn blockRange(self: Walk, index: usize) ?struct { start: u64, end: u64 } {
        if (index >= self.block_count) return null;
        return .{ .start = readU64(self.map, index * 8), .end = readU64(self.map, (index + 1) * 8) };
    }
};

/// `image` is the decrypted PFS image, or the raw image when the pkg stores it unencrypted.
/// Only the blocks reachable inside `image` are read, so callers pass at least the first
/// `pfs_cache_size * 2` bytes as the reference implementation does.
pub fn walk(arena: std.mem.Allocator, image: []const u8) Error!Walk {
    const pfsc_offset = findPfsc(image) orelse return error.NoPfsc;

    const header = image[pfsc_offset..];
    if (header.len < 0x30) return error.BadPfscHeader;
    const block_size2 = readU64(header, 0x10);
    const block_offsets = readU64(header, 0x18);
    const data_length = readU64(header, 0x28);
    if (block_size2 != block_size) return error.BadPfscHeader;

    const block_count: usize = @intCast(data_length / block_size2); // checked against the map below
    const map_start = std.math.add(usize, pfsc_offset, @intCast(block_offsets)) catch
        return error.BadPfscHeader;
    if (map_start + (block_count + 1) * 8 > image.len) return error.BlockOutOfRange;
    const map = image[map_start..];

    const block0 = try readBlock(arena, image, pfsc_offset, map, 0);
    const inode_count: usize = readU32(block0, 0x30);
    if (inode_count == 0) return error.BadPfscHeader;
    const inode_blocks = (inode_count * inode_stride + block_size - 1) / block_size;

    var inodes = try arena.alloc(Inode, inode_count);
    var inode_found: usize = 0;
    var b: usize = 1;
    while (b <= inode_blocks and b < block_count) : (b += 1) {
        const block = try readBlock(arena, image, pfsc_offset, map, b);
        var off: usize = 0;
        while (off + inode_stride <= block.len and inode_found < inode_count) : (off += inode_stride) {
            const mode = readU16(block, off + inode_mode_offset);
            if (mode == 0) break;
            inodes[inode_found] = .{
                .mode = mode,
                .size = @bitCast(readU64(block, off + inode_size_offset)),
                .blocks = readU32(block, off + inode_blocks_offset),
                .loc = readU32(block, off + inode_loc_offset),
            };
            inode_found += 1;
        }
    }
    if (inode_found != inode_count) return error.BadPfscHeader;
    inodes = inodes[0..inode_found];

    // Directory blocks follow the inode blocks, interleaved with file data blocks. Each
    // directory block starts with ".<self>" then "..<parent>".
    const DirBlock = struct { self_ino: u32, bytes: []const u8 };
    var dir_blocks = std.ArrayList(DirBlock).empty;
    var block_index: usize = inode_blocks + 1;
    while (block_index < block_count) : (block_index += 1) {
        const raw = readBlock(arena, image, pfsc_offset, map, block_index) catch |err| switch (err) {
            error.BlockOutOfRange => break,
            else => return err,
        };
        const first = parseDirent(raw, 0) catch continue;
        if (first.type != dirent_type_self) continue;
        const second = parseDirent(raw, first.entsize) catch continue;
        if (second.type != dirent_type_parent) continue;
        try dir_blocks.append(arena, .{ .self_ino = first.ino, .bytes = raw });
    }
    if (dir_blocks.items.len == 0) return error.BadDirent;

    // Directory names come from the parent's listing, never from the "." entry.
    const dir_parent = try arena.alloc(?u32, inode_count);
    const dir_name = try arena.alloc(?[]const u8, inode_count);
    @memset(dir_parent, null);
    @memset(dir_name, null);
    var root_ino: ?u32 = null;
    for (dir_blocks.items) |block| {
        const self_entry = parseDirent(block.bytes, 0) catch continue;
        const parent_entry = parseDirent(block.bytes, self_entry.entsize) catch continue;
        if (parent_entry.ino == self_entry.ino) root_ino = self_entry.ino;
        var off: usize = self_entry.entsize + parent_entry.entsize;
        while (off < block.bytes.len) {
            const dirent = parseDirent(block.bytes, off) catch break;
            off += dirent.entsize;
            if (dirent.type != dirent_type_dir) continue;
            if (dirent.ino >= inode_count) return error.MissingInode;
            dir_parent[dirent.ino] = self_entry.ino;
            dir_name[dirent.ino] = try arena.dupe(u8, dirent.name);
        }
    }
    const root = root_ino orelse return error.BadDirent;

    const dir_paths = try arena.alloc(?[]const u8, inode_count);
    @memset(dir_paths, null);
    dir_paths[root] = "";
    var pass: usize = 0;
    while (pass <= inode_count) : (pass += 1) {
        var progress = false;
        for (dir_blocks.items) |block| {
            const self_entry = parseDirent(block.bytes, 0) catch continue;
            if (dir_paths[self_entry.ino] != null) continue;
            const parent = dir_parent[self_entry.ino] orelse continue;
            const parent_path = dir_paths[parent] orelse continue;
            const name = dir_name[self_entry.ino] orelse continue;
            dir_paths[self_entry.ino] = try joinPath(arena, parent_path, name);
            progress = true;
        }
        if (!progress) break;
    }

    var entries = std.ArrayList(Entry).empty;
    for (dir_blocks.items) |block| {
        const self_entry = parseDirent(block.bytes, 0) catch return error.BadDirent;
        const dir_ino = self_entry.ino;
        const dir_path = dir_paths[dir_ino] orelse return error.BadDirent;

        var off: usize = self_entry.entsize;
        const parent = parseDirent(block.bytes, off) catch return error.BadDirent;
        off += parent.entsize;
        while (off < block.bytes.len) {
            const dirent = parseDirent(block.bytes, off) catch break;
            off += dirent.entsize;
            if (dirent.type != dirent_type_file and dirent.type != dirent_type_dir) continue;
            if (dirent.ino >= inode_count) return error.MissingInode;
            const inode = inodes[dirent.ino];
            if (inode.mode == 0) return error.MissingInode;

            const path = try joinPath(arena, dir_path, dirent.name);
            try entries.append(arena, .{
                .path = path,
                .inode = dirent.ino,
                .kind = if (dirent.type == dirent_type_dir) .dir else .file,
                .size = inode.size,
                .blocks = inode.blocks,
                .loc = inode.loc,
            });
        }
    }

    return .{
        .entries = try entries.toOwnedSlice(arena),
        .inodes = inodes,
        .pfsc_offset = pfsc_offset,
        .map = map[0 .. (block_count + 1) * 8],
        .block_count = block_count,
    };
}

const Dirent = struct {
    ino: u32,
    type: u32,
    entsize: usize,
    name: []const u8,
};

fn parseDirent(block: []const u8, offset: usize) Error!Dirent {
    if (offset + 16 > block.len) return error.BadDirent;
    const ino = readU32(block, offset);
    const kind = readU32(block, offset + 4);
    const namelen: usize = readU32(block, offset + 8);
    const entsize: usize = readU32(block, offset + 12);
    if (entsize < 16 + namelen or entsize > 16 + 512) return error.BadDirent;
    if (offset + entsize > block.len) return error.BadDirent;
    if (namelen == 0) return error.BadDirent;
    if (kind < dirent_type_file or kind > dirent_type_parent) return error.BadDirent;
    return .{
        .ino = ino,
        .type = kind,
        .entsize = entsize,
        .name = block[offset + 16 .. offset + 16 + namelen],
    };
}

fn joinPath(arena: std.mem.Allocator, parent: []const u8, name: []const u8) ![]const u8 {
    if (parent.len == 0) return arena.dupe(u8, name);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, name });
}

fn findPfsc(image: []const u8) ?usize {
    var offset: usize = 0x20000;
    while (offset + 4 <= image.len) : (offset += block_size) {
        if (readU32(image, offset) == pfsc_magic) return offset;
    }
    return null;
}

fn readBlock(
    arena: std.mem.Allocator,
    image: []const u8,
    pfsc_offset: usize,
    map: []const u8,
    index: usize,
) Error![]const u8 {
    if ((index + 1) * 8 > map.len) return error.BlockOutOfRange;
    const start: usize = @intCast(readU64(map, index * 8));
    const end: usize = @intCast(readU64(map, (index + 1) * 8));
    const block_start = std.math.add(usize, pfsc_offset, start) catch return error.BlockOutOfRange;
    const block_end = std.math.add(usize, pfsc_offset, end) catch return error.BlockOutOfRange;
    if (end < start or block_end > image.len) return error.BlockOutOfRange;

    if (end - start == block_size) return arena.dupe(u8, image[block_start..block_end]);
    if (end == start) return error.BadPfscHeader;

    var in: std.Io.Reader = .fixed(image[block_start..block_end]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const out = try arena.alloc(u8, block_size);
    var writer: std.Io.Writer = .fixed(out);
    _ = decompress.reader.streamRemaining(&writer) catch return error.InflateFailed;
    if (writer.end == 0) return error.InflateFailed;
    return out[0..writer.end];
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}
