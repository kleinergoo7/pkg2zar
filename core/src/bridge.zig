// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! C ABI surface for the Qt shell. One job at a time, no global state beyond the cancel flag.

const std = @import("std");
const source = @import("source.zig");
const plan_mod = @import("plan.zig");
const exporter = @import("export.zig");
const extractor = @import("extract.zig");
const probe = @import("probe.zig");
const naming = @import("naming.zig");
const pieces = @import("pieces.zig");

pub const ABI_VERSION: u32 = 7;

pub const ProgressFn = *const fn (ctx: ?*anyopaque, done: u64, total: u64, current: [*]const u8, current_len: usize) callconv(.c) void;

var cancel_flag = std.atomic.Value(bool).init(false);

var progress_fn: ?ProgressFn = null;
var progress_ctx: ?*anyopaque = null;

export fn p2z_abi_version() u32 {
    return ABI_VERSION;
}

/// Fills title, title id, version and the patch flag without touching crypto.
/// Returns 0 on success, 1 on failure with a message in `err`.
export fn p2z_probe(
    path: [*:0]const u8,
    title: [*]u8,
    title_len: usize,
    title_id: [*]u8,
    id_len: usize,
    version: [*]u8,
    version_len: usize,
    is_patch: *c_int,
    err: [*]u8,
    err_len: usize,
) c_int {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    const info = probe.run(threaded.io(), arena, std.mem.span(path)) catch |failure| {
        writeMessage(err, err_len, probe.reasonName(failure));
        return 1;
    };
    copyOut(info.title orelse "", title, title_len);
    copyOut(info.title_id orelse "", title_id, id_len);
    copyOut(info.version orelse "", version, version_len);
    is_patch.* = if (info.is_patch) 1 else 0;
    return 0;
}

/// Builds the default output name. Role: 0 single, 1 merged, 2 base, 3 update.
/// Writes the name, with `.zar` unless `extract` is non-zero, NUL-terminated into `out`.
export fn p2z_output_name(
    role: c_int,
    title: [*:0]const u8,
    title_id: [*:0]const u8,
    version: [*:0]const u8,
    extract: c_int,
    out: [*]u8,
    out_len: usize,
) c_int {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const requested = std.enums.fromInt(naming.Role, role) orelse return 1;
    var info: naming.Info = .{ .role = requested };
    if (std.mem.span(title).len > 0) info.title = std.mem.span(title);
    if (std.mem.span(title_id).len > 0) info.title_id = std.mem.span(title_id);
    if (std.mem.span(version).len > 0) info.version = std.mem.span(version);

    const name = naming.derive(arena, info, "output") catch return 1;
    const full = if (extract != 0)
        name
    else
        std.fmt.allocPrint(arena, "{s}.zar", .{name}) catch return 1;
    copyOut(full, out, out_len);
    return 0;
}

export fn p2z_cancel() void {
    cancel_flag.store(true, .release);
}

fn report(_: ?*anyopaque, progress: exporter.Progress) void {
    if (progress_fn) |callback| callback(progress_ctx, progress.done, progress.total, progress.current.ptr, progress.current.len);
}

/// Job mode. AUTO groups a piece set when the names say so, otherwise one input converts and
/// two inputs merge. MERGE forces base + update. SINGLE treats every input as one piece set.
pub const Mode = enum(c_int) {
    auto = 0,
    merge = 1,
    single = 2,
};

/// Output kind: a `.zar` archive, or an extracted folder tree.
pub const Kind = enum(c_int) {
    archive = 0,
    extract = 1,
};

/// Runs one convert or merge job. Returns 0 on success, 2 when cancelled, 1 on any error with
/// a user-facing message in `err`.
export fn p2z_run(
    mode: c_int,
    kind: c_int,
    allow_overwrite: c_int,
    output: [*:0]const u8,
    inputs: [*]const [*:0]const u8,
    input_count: usize,
    callback: ?ProgressFn,
    ctx: ?*anyopaque,
    err: [*]u8,
    err_len: usize,
) c_int {
    cancel_flag.store(false, .release);
    progress_fn = callback;
    progress_ctx = ctx;

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (input_count == 0) {
        writeMessage(err, err_len, "select one pkg to convert, or a base and an update to merge");
        return 1;
    }

    const paths = arena.alloc([]const u8, input_count) catch {
        writeMessage(err, err_len, "out of memory");
        return 1;
    };
    for (0..input_count) |i| paths[i] = std.mem.span(inputs[i]);

    const requested = std.enums.fromInt(Mode, mode) orelse {
        writeMessage(err, err_len, "unknown mode");
        return 1;
    };
    const grouped = switch (requested) {
        .single => true,
        .merge => false,
        .auto => pieces.looksLikeSet(paths),
    };
    const source_count: usize = if (grouped) 1 else input_count;
    if (!grouped and input_count > 2) {
        writeMessage(err, err_len, "select at most two pkgs: a base and an update");
        return 1;
    }

    var sources: [2]source.Source = undefined;
    var opened: usize = 0;
    defer for (sources[0..opened]) |s| s.close();

    if (grouped) {
        const result = source.Source.open(io, arena, paths) catch {
            writeMessage(err, err_len, "out of memory");
            return 1;
        };
        switch (result) {
            .ok => |src| {
                sources[0] = src;
                opened = 1;
            },
            .fail => |fail| {
                var buf: [512]u8 = undefined;
                writeMessage(err, err_len, source.describe(fail, &buf));
                return 1;
            },
        }
    }
    if (!grouped) {
        for (paths, 0..) |path, i| {
            const result = source.Source.open(io, arena, &.{path}) catch {
                writeMessage(err, err_len, "out of memory");
                return 1;
            };
            switch (result) {
                .ok => |src| {
                    sources[i] = src;
                    opened += 1;
                },
                .fail => |fail| {
                    var buf: [512]u8 = undefined;
                    writeMessage(err, err_len, source.describe(fail, &buf));
                    return 1;
                },
            }
        }
    }

    var base_identity = plan_mod.Identity.fromSource(&sources[0]);
    var update_identity = if (source_count == 2) plan_mod.Identity.fromSource(&sources[1]) else null;
    var swapped = false;
    if (update_identity) |upd| {
        if (plan_mod.shouldSwapRoles(base_identity, upd)) {
            std.mem.swap(source.Source, &sources[0], &sources[1]);
            base_identity = upd;
            update_identity = plan_mod.Identity.fromSource(&sources[1]);
            swapped = true;
        }
    }
    if (plan_mod.preflight(base_identity, update_identity)) |failure| {
        var buf: [512]u8 = undefined;
        writeMessage(err, err_len, plan_mod.describe(failure, &buf));
        return 1;
    }

    const plan = plan_mod.build(arena, sources[0..source_count]) catch {
        writeMessage(err, err_len, "out of memory");
        return 1;
    };

    const out_kind = std.enums.fromInt(Kind, kind) orelse {
        writeMessage(err, err_len, "unknown output kind");
        return 1;
    };
    switch (out_kind) {
        .archive => {
            _ = exporter.run(arena, io, sources[0..source_count], &plan, .{
                .output = std.mem.span(output),
                .overwrite = allow_overwrite != 0,
                .cancel = &cancel_flag,
                .on_progress = report,
            }) catch |failure| return failureCode(err, err_len, failure, exporter.reasonName);
        },
        .extract => {
            _ = extractor.run(arena, io, sources[0..source_count], &plan, .{
                .output = std.mem.span(output),
                .overwrite = allow_overwrite != 0,
                .cancel = &cancel_flag,
                .on_progress = report,
            }) catch |failure| return failureCode(err, err_len, failure, extractor.reasonName);
        },
    }
    if (swapped) {
        writeMessage(err, err_len, "note: inputs were swapped, the update was listed first");
    }
    return 0;
}

fn failureCode(buffer: [*]u8, len: usize, failure: anyerror, comptime reasonName: anytype) c_int {
    if (failure == error.OutOfMemory) {
        writeMessage(buffer, len, "out of memory");
        return 1;
    }
    if (failure == error.Cancelled) {
        writeMessage(buffer, len, reasonName(error.Cancelled));
        return 2;
    }
    writeMessage(buffer, len, reasonName(@errorCast(failure)));
    return 1;
}

fn copyOut(source_text: []const u8, buffer: [*]u8, len: usize) void {
    if (len == 0) return;
    const n = @min(len - 1, source_text.len);
    @memcpy(buffer[0..n], source_text[0..n]);
    buffer[n] = 0;
}

fn writeMessage(buffer: [*]u8, len: usize, message: []const u8) void {
    if (len == 0) return;
    const n = @min(len - 1, message.len);
    @memcpy(buffer[0..n], message[0..n]);
    buffer[n] = 0;
}

test "integration: p2z_run converts through the C ABI" {
    const path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;

    const output = ".zig-cache/p2z-bridge-test.zar";
    std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, output ++ ".part") catch {};

    const output_z = try std.testing.allocator.allocSentinel(u8, output.len, 0);
    @memcpy(output_z, output);
    defer std.testing.allocator.free(output_z);
    const input_z = try std.testing.allocator.allocSentinel(u8, path.len, 0);
    @memcpy(input_z, path);
    defer std.testing.allocator.free(input_z);
    const inputs = [_][*:0]const u8{input_z.ptr};

    var err: [256]u8 = undefined;
    TestProgress.last_done = 0;

    const code = p2z_run(@backingInt(Mode.single), @backingInt(Kind.archive), 0, output_z.ptr, &inputs, 1, TestProgress.cb, null, &err, err.len);
    try std.testing.expectEqual(@as(c_int, 0), code);
    try std.testing.expect(TestProgress.last_done > 0);
    try std.testing.expect(exists(output));
}

const TestProgress = struct {
    var last_done: u64 = 0;
    fn cb(_: ?*anyopaque, done: u64, _: u64, _: [*]const u8, _: usize) callconv(.c) void {
        last_done = done;
    }
};

fn exists(path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch return false;
    file.close(std.testing.io);
    return true;
}

test "integration: merge accepts the update listed first" {
    const base_path = if (std.c.getenv("P2Z_TEST_PKG")) |p| std.mem.span(p) else return error.SkipZigTest;
    const update_path = if (std.c.getenv("P2Z_TEST_UPDATE")) |p| std.mem.span(p) else return error.SkipZigTest;

    const output = ".zig-cache/p2z-bridge-swap.zar";
    std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output) catch {};

    const output_z = try std.testing.allocator.allocSentinel(u8, output.len, 0);
    @memcpy(output_z, output);
    defer std.testing.allocator.free(output_z);
    const update_z = try std.testing.allocator.allocSentinel(u8, update_path.len, 0);
    @memcpy(update_z, update_path);
    defer std.testing.allocator.free(update_z);
    const base_z = try std.testing.allocator.allocSentinel(u8, base_path.len, 0);
    @memcpy(base_z, base_path);
    defer std.testing.allocator.free(base_z);

    // Update first on purpose: the roles must be detected, not taken from the order.
    const inputs = [_][*:0]const u8{ update_z.ptr, base_z.ptr };
    var err: [256]u8 = @splat(0);
    const code = p2z_run(@backingInt(Mode.auto), @backingInt(Kind.archive), 0, output_z.ptr, &inputs, 2, null, null, &err, err.len);
    try std.testing.expectEqual(@as(c_int, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, &err, "swapped") != null);
    try std.testing.expect(exists(output));
}
