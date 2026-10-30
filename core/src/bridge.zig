// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! C ABI surface for the Qt shell. One job at a time, no global state beyond the cancel flag.

const std = @import("std");
const source = @import("source.zig");
const plan_mod = @import("plan.zig");
const exporter = @import("export.zig");

pub const ABI_VERSION: u32 = 1;

pub const ProgressFn = *const fn (ctx: ?*anyopaque, done: u64, total: u64) callconv(.c) void;

var cancel_flag = std.atomic.Value(bool).init(false);

var progress_fn: ?ProgressFn = null;
var progress_ctx: ?*anyopaque = null;

export fn p2z_abi_version() u32 {
    return ABI_VERSION;
}

export fn p2z_cancel() void {
    cancel_flag.store(true, .release);
}

fn report(_: ?*anyopaque, progress: exporter.Progress) void {
    if (progress_fn) |callback| callback(progress_ctx, progress.done, progress.total);
}

/// Runs one convert or merge job. Returns 0 on success, 2 when cancelled, 1 on any error with
/// a user-facing message in `err`.
export fn p2z_run(
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

    if (input_count == 0 or input_count > 2) {
        writeMessage(err, err_len, "select one pkg to convert, or a base and an update to merge");
        return 1;
    }

    const paths = arena.alloc([]const u8, input_count) catch {
        writeMessage(err, err_len, "out of memory");
        return 1;
    };
    for (0..input_count) |i| paths[i] = std.mem.span(inputs[i]);

    var sources: [2]source.Source = undefined;
    var opened: usize = 0;
    defer for (sources[0..opened]) |s| s.close();

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

    const base_identity = plan_mod.Identity.fromSource(&sources[0]);
    const update_identity = if (input_count == 2) plan_mod.Identity.fromSource(&sources[1]) else null;
    if (plan_mod.preflight(base_identity, update_identity)) |failure| {
        var buf: [512]u8 = undefined;
        writeMessage(err, err_len, plan_mod.describe(failure, &buf));
        return 1;
    }

    const plan = plan_mod.build(arena, sources[0..input_count]) catch {
        writeMessage(err, err_len, "out of memory");
        return 1;
    };

    const stats = exporter.run(arena, io, sources[0..input_count], &plan, .{
        .output = std.mem.span(output),
        .cancel = &cancel_flag,
        .on_progress = report,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => {
            writeMessage(err, err_len, "out of memory");
            return 1;
        },
        error.Cancelled => {
            writeMessage(err, err_len, exporter.reasonName(error.Cancelled));
            return 2;
        },
        else => |e| {
            writeMessage(err, err_len, exporter.reasonName(e));
            return 1;
        },
    };

    _ = stats;
    return 0;
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

    const output_z = try std.testing.allocator.dupeZ(u8, output);
    defer std.testing.allocator.free(output_z);
    const input_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(input_z);
    const inputs = [_][*:0]const u8{input_z.ptr};

    var err: [256]u8 = undefined;
    TestProgress.last_done = 0;

    const code = p2z_run(output_z.ptr, &inputs, 1, TestProgress.cb, null, &err, err.len);
    try std.testing.expectEqual(@as(c_int, 0), code);
    try std.testing.expect(TestProgress.last_done > 0);
    try std.testing.expect(exists(output));
}

const TestProgress = struct {
    var last_done: u64 = 0;
    fn cb(_: ?*anyopaque, done: u64, _: u64) callconv(.c) void {
        last_done = done;
    }
};

fn exists(path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch return false;
    file.close(std.testing.io);
    return true;
}
