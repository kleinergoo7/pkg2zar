// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! dvui front end. All work happens in p2z.bridge on a worker thread; this file only
//! collects input, paints state and forwards cancel.

const std = @import("std");
const dvui = @import("dvui");
const p2z = @import("p2z");
const build_options = @import("build_options");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 820.0, .h = 640.0 },
            .min_size = .{ .w = 620.0, .h = 480.0 },
            .title = "ps4-pkg2zar " ++ build_options.version,
            .app = "ps4-pkg2zar",
            .org = "ps4-pkg2zar",
        },
    },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const Input = struct {
    path: []u8,
    title: []u8 = &.{},
    id: []u8 = &.{},
    version: []u8 = &.{},
    patch: bool = false,
    probed: bool = false,
    /// An already extracted folder: archived as-is, never probed or merged.
    is_dir: bool = false,
};

const Unit = struct {
    inputs: [][]u8,
    output: []u8,
    mode: p2z.bridge.Mode,
    folder: bool = false,
};

const Job = struct {
    units: []Unit,
    /// One outcome per unit, so each input gets its own result line.
    outcomes: []p2z.bridge.Outcome,
    unit_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    kind: p2z.bridge.Kind,
    overwrite: bool,
    done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// `p2z.bridge.Outcome` as an integer: std.atomic.Value rejects enums.
    code: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(p2z.bridge.Outcome.failed)),
    current_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    current: [512]u8 = @splat(0),
    error_buf: [512]u8 = @splat(0),
    thread: std.Thread = undefined,
};

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    threaded: std.Io.Threaded,
    arena_state: std.heap.ArenaAllocator,
    inputs: std.ArrayList(Input) = .empty,
    output: std.ArrayList(u8) = .empty,
    output_edited: bool = false,
    extract: bool = false,
    separate: bool = false,
    log: std.ArrayList([]u8) = .empty,
    job: ?*Job = null,
    pending_overwrite: bool = false,
    last_logged_percent: u64 = 255,
};

var state: State = undefined;

fn init(_: *dvui.Window) !void {
    state = .{
        .gpa = std.heap.page_allocator,
        .io = undefined,
        .threaded = undefined,
        .arena_state = undefined,
    };
    state.threaded = .init(state.gpa, .{});
    state.io = state.threaded.io();
    state.arena_state = .init(state.gpa);
    state.output.appendSlice(state.gpa, "") catch @panic("OOM");
    log("Drop pkg files with Add files. One input converts, two merge.", .{});
}

fn deinit(_: *dvui.Window) void {
    if (state.job) |job| {
        _ = job;
    }
    for (state.inputs.items) |input| {
        state.gpa.free(input.path);
        if (input.title.len > 0) state.gpa.free(input.title);
        if (input.id.len > 0) state.gpa.free(input.id);
        if (input.version.len > 0) state.gpa.free(input.version);
    }
    state.inputs.deinit(state.gpa);
    state.output.deinit(state.gpa);
    for (state.log.items) |line| state.gpa.free(line);
    state.log.deinit(state.gpa);
    state.arena_state.deinit();
    state.threaded.deinit();
}

fn log(comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.allocPrint(state.gpa, fmt, args) catch return;
    logOwned(line);
}

fn logOwned(text: []const u8) void {
    const line = state.gpa.dupe(u8, text) catch return;
    state.log.append(state.gpa, line) catch {
        state.gpa.free(line);
        return;
    };
}

fn busy() bool {
    const job = state.job orelse return false;
    return job.running.load(.acquire);
}

fn frame() !dvui.App.Result {
    pollJob();

    if (busy()) {
        dvui.refresh(null, @src(), null);
    }

    var top = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .style = .window });
    defer top.deinit();

    header();
    outputs();
    controls();
    progressBar();
    logPane();

    return .ok;
}

fn header() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    if (dvui.button(@src(), "Add files", .{}, .{ .min_size_content = .{ .w = 110, .h = 30 } })) {
        addFilesDialog();
    }
    if (dvui.button(@src(), "Add folder", .{}, .{ .min_size_content = .{ .w = 110, .h = 30 } })) {
        addFolderDialog();
    }
    dvui.label(@src(), "{d} input(s)", .{state.inputs.items.len}, .{});

    var list = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .h = 140 } });
    defer list.deinit();
    var i: usize = 0;
    while (i < state.inputs.items.len) : (i += 1) {
        const input = state.inputs.items[i];
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer line.deinit();
        if (dvui.button(@src(), "x", .{}, .{ .min_size_content = .{ .w = 26, .h = 22 } })) {
            removeInput(i);
            break;
        }
        dvui.label(@src(), "{s}", .{input.path}, .{ .expand = .horizontal });
        if (input.is_dir) {
            dvui.label(@src(), "(folder)", .{}, .{});
        } else if (input.probed) {
            dvui.label(@src(), "{s} ({s}) v{s}{s}", .{
                input.title,
                input.id,
                input.version,
                if (input.patch) " patch" else "",
            }, .{});
        }
    }
}

fn outputs() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    dvui.label(@src(), "Output:", .{}, .{});
    var entry = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{ .backing = &state.output, .allocator = state.gpa } } }, .{ .expand = .horizontal, .min_size_content = .{ .h = 28 } });
    entry.deinit();
    if (entry.text_changed) state.output_edited = true;

    if (dvui.button(@src(), "Browse", .{}, .{ .min_size_content = .{ .w = 90, .h = 28 } })) {
        browseOutput();
    }
}

fn controls() void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    if (dvui.checkbox(@src(), &state.extract, "Extract folder", .{})) {
        state.output_edited = false;
        autoOutput();
    }
    if (dvui.checkbox(@src(), &state.separate, "Each separately", .{})) {
        state.output_edited = false;
        autoOutput();
    }
    if (dvui.button(@src(), "Convert", .{}, .{ .min_size_content = .{ .w = 100, .h = 30 } })) {
        startConversion();
    }
    if (dvui.button(@src(), "Cancel", .{}, .{ .min_size_content = .{ .w = 100, .h = 30 } })) {
        p2z.bridge.cancel();
        log("Cancelling...", .{});
    }
}

fn progressBar() void {
    const job = state.job orelse return;
    const count = job.units.len;
    const index = @min(job.unit_index.load(.acquire), count - 1);
    // One bar per unit: a sequence of separate outputs must not look like one long job.
    if (count > 1) {
        dvui.label(@src(), "{d}/{d}  {s}", .{ index + 1, count, std.fs.path.basename(job.units[index].output) }, .{});
    }

    const total = job.total.load(.acquire);
    const done = job.done.load(.acquire);
    const percent: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    dvui.progress(@src(), .{ .percent = percent }, .{ .expand = .horizontal, .min_size_content = .{ .h = 14 } });

    const current_len = job.current_len.load(.acquire);
    if (current_len > 0) dvui.label(@src(), "{s}", .{job.current[0..current_len]}, .{});
}

fn logPane() void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .h = 120 } });
    defer scroll.deinit();
    for (state.log.items) |line| {
        dvui.label(@src(), "{s}", .{line}, .{ .expand = .horizontal });
    }
}

fn addFilesDialog() void {
    const paths = dvui.dialogNativeFileOpenMultiple(state.gpa, .{
        .title = "Select pkg files",
        .filters = &.{"*.pkg"},
        .filter_description = "PS4 packages",
    }) catch null;
    const selected = paths orelse return;
    for (selected) |path| addInput(path);
    state.output_edited = false;
    autoOutput();
}

fn addFolderDialog() void {
    const path = dvui.dialogNativeFolderSelect(state.gpa, .{ .title = "Select an extracted folder" }) catch null;
    const selected = path orelse return;
    addFolder(selected);
    state.output_edited = false;
    autoOutput();
}

fn browseOutput() void {
    const current = std.mem.trim(u8, state.output.items, " \t\r\n");
    if (state.extract) {
        const dir = dvui.dialogNativeFolderSelect(state.gpa, .{ .title = "Output folder", .path = current }) catch null;
        if (dir) |d| {
            state.output.clearRetainingCapacity();
            state.output.appendSlice(state.gpa, d) catch return;
            state.output_edited = true;
        }
    } else {
        const file = dvui.dialogNativeFileSave(state.gpa, .{ .title = "Save archive", .path = current }) catch null;
        if (file) |f| {
            state.output.clearRetainingCapacity();
            state.output.appendSlice(state.gpa, f) catch return;
            state.output_edited = true;
        }
    }
}

fn addInput(path: []const u8) void {
    for (state.inputs.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) return;
    }
    var input: Input = .{ .path = state.gpa.dupe(u8, path) catch return };
    const info = p2z.probe.run(state.io, state.gpa, path) catch |err| {
        log("{s}: {s}", .{ path, p2z.probe.reasonName(err) });
        state.inputs.append(state.gpa, input) catch {};
        return;
    };
    if (info.title) |t| input.title = state.gpa.dupe(u8, t) catch &.{};
    if (info.title_id) |id| input.id = state.gpa.dupe(u8, id) catch &.{};
    if (info.version) |v| input.version = state.gpa.dupe(u8, v) catch &.{};
    input.patch = info.is_patch;
    input.probed = true;
    log("{s}: {s} ({s}) v{s}{s}", .{ path, input.title, input.id, input.version, if (input.patch) " patch" else "" });
    state.inputs.append(state.gpa, input) catch {};
}

fn addFolder(path: []const u8) void {
    for (state.inputs.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) return;
    }
    var input: Input = .{
        .path = state.gpa.dupe(u8, path) catch return,
        .is_dir = true,
        .probed = true,
    };
    // The folder carries the game identity in sce_sys/param.sfo, exactly like a pkg does.
    const info = p2z.probe.runFolder(state.io, state.gpa, path) catch |err| {
        log("{s}: folder, {s}", .{ path, p2z.probe.reasonName(err) });
        state.inputs.append(state.gpa, input) catch {};
        return;
    };
    if (info.title) |t| input.title = state.gpa.dupe(u8, t) catch &.{};
    if (info.title_id) |id| input.id = state.gpa.dupe(u8, id) catch &.{};
    if (info.version) |v| input.version = state.gpa.dupe(u8, v) catch &.{};
    if (input.title.len > 0) {
        log("{s}: folder, {s} ({s}) v{s}", .{ path, input.title, input.id, input.version });
    } else {
        log("{s}: folder without sce_sys/param.sfo, named after the directory", .{path});
    }
    state.inputs.append(state.gpa, input) catch {};
}

fn removeInput(index: usize) void {
    if (busy()) return;
    const input = state.inputs.orderedRemove(index);
    state.gpa.free(input.path);
    if (input.title.len > 0) state.gpa.free(input.title);
    if (input.id.len > 0) state.gpa.free(input.id);
    if (input.version.len > 0) state.gpa.free(input.version);
    state.output_edited = false;
    autoOutput();
}

fn roleOf(input: Input, separate: bool, count: usize) p2z.naming.Role {
    if (separate and count > 1) return if (input.patch) .update else .base;
    if (count > 1) return .merged;
    return .single;
}

fn folderBase(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    return std.fs.path.basename(path[0..end]);
}

fn derivedName(index: usize) ?[]u8 {
    const input = state.inputs.items[index];
    if (input.is_dir) {
        var folder_arena = state.arena_state;
        defer folder_arena.deinit();
        const info: p2z.naming.Info = .{
            .title = if (input.title.len > 0) input.title else null,
            .title_id = if (input.id.len > 0) input.id else null,
            .version = if (input.version.len > 0) input.version else null,
            .role = .single,
        };
        // derive falls back to the folder name when the identity is empty.
        const name = p2z.naming.derive(folder_arena.allocator(), info, folderBase(input.path)) catch return null;
        return std.fmt.allocPrint(state.gpa, "{s}.zar", .{name}) catch null;
    }
    if (!input.probed) return null;
    var arena = state.arena_state;
    defer arena.deinit();
    const info: p2z.naming.Info = .{
        .title = if (input.title.len > 0) input.title else null,
        .title_id = if (input.id.len > 0) input.id else null,
        .version = if (input.version.len > 0) input.version else null,
        .role = roleOf(input, state.separate, state.inputs.items.len),
    };
    const name = p2z.naming.derive(arena.allocator(), info, input.path) catch return null;
    const full = std.fmt.allocPrint(state.gpa, "{s}{s}", .{ name, if (state.extract) "" else ".zar" }) catch return null;
    return full;
}

fn autoOutput() void {
    if (state.inputs.items.len == 0) return;
    if (state.output_edited) return;
    const dir = std.fs.path.dirname(state.inputs.items[0].path) orelse ".";
    if (state.separate and state.inputs.items.len > 1) {
        state.output.clearRetainingCapacity();
        state.output.appendSlice(state.gpa, dir) catch return;
    } else {
        // Derive first: a failed derivation must not wipe a usable output path.
        const name = derivedName(0) orelse return;
        defer state.gpa.free(name);
        state.output.clearRetainingCapacity();
        state.output.appendSlice(state.gpa, dir) catch return;
        state.output.append(state.gpa, '/') catch return;
        state.output.appendSlice(state.gpa, name) catch return;
    }
}

fn startConversion() void {
    if (busy()) return;
    if (state.inputs.items.len == 0) {
        log("Add at least one pkg.", .{});
        return;
    }
    const output = std.mem.trim(u8, state.output.items, " \t\r\n");
    if (output.len == 0) {
        log("Choose an output path.", .{});
        return;
    }

    var folders: usize = 0;
    for (state.inputs.items) |input| {
        if (input.is_dir) folders += 1;
    }
    if (folders > 0) {
        if (folders != state.inputs.items.len) {
            log("Do not mix pkgs and folders; add one kind at a time.", .{});
            return;
        }
        if (state.extract) {
            log("Extract needs pkg inputs; a folder is already extracted.", .{});
            return;
        }
        if (state.inputs.items.len > 1 and !state.separate) {
            log("One archive takes one folder; tick Each separately for several.", .{});
            return;
        }
    }

    const kind: p2z.bridge.Kind = if (state.extract) .extract else .archive;
    const separate = state.separate and state.inputs.items.len > 1;

    var targets: std.ArrayList([]u8) = .empty;
    defer {
        for (targets.items) |target| state.gpa.free(target);
        targets.deinit(state.gpa);
    }
    if (separate) {
        const dir = if (std.mem.endsWith(u8, output, "/")) output else std.fs.path.dirname(output) orelse ".";
        for (state.inputs.items, 0..) |_, i| {
            const name = derivedName(i) orelse continue;
            defer state.gpa.free(name);
            const target = std.fmt.allocPrint(state.gpa, "{s}/{s}", .{ dir, name }) catch return;
            targets.append(state.gpa, target) catch return;
        }
    } else {
        targets.append(state.gpa, state.gpa.dupe(u8, output) catch return) catch return;
    }
    if (targets.items.len == 0) {
        log("Could not derive output names.", .{});
        return;
    }

    var existing: usize = 0;
    for (targets.items) |target| {
        std.Io.Dir.cwd().access(state.io, target, .{}) catch continue;
        existing += 1;
    }
    var overwrite = false;
    if (existing > 0) {
        if (!state.pending_overwrite) {
            state.pending_overwrite = true;
            log("{d} output(s) exist. Click Convert again to replace.", .{existing});
            return;
        }
        overwrite = true;
    }
    state.pending_overwrite = false;

    const job = state.gpa.create(Job) catch return;
    const units = state.gpa.alloc(Unit, targets.items.len) catch return;
    const outcomes = state.gpa.alloc(p2z.bridge.Outcome, targets.items.len) catch return;
    @memset(outcomes, .failed);
    job.* = .{ .units = units, .outcomes = outcomes, .kind = kind, .overwrite = overwrite };

    for (targets.items, 0..) |target, i| {
        const source_indexes: []const usize = if (separate)
            &[_]usize{i}
        else blk: {
            const all = state.gpa.alloc(usize, state.inputs.items.len) catch return;
            for (all, 0..) |*slot, n| slot.* = n;
            break :blk all;
        };
        const inputs = state.gpa.alloc([]u8, source_indexes.len) catch return;
        for (source_indexes, 0..) |src, n| {
            inputs[n] = state.gpa.dupe(u8, state.inputs.items[src].path) catch return;
        }
        units[i] = .{
            .inputs = inputs,
            .output = state.gpa.dupe(u8, target) catch return,
            .mode = if (separate) .single else .auto,
            .folder = state.inputs.items[source_indexes[0]].is_dir,
        };
    }

    job.thread = std.Thread.spawn(.{}, worker, .{job}) catch return;
    state.job = job;
    log("Starting {s}{s}...", .{
        if (units[0].folder)
            "archive of a folder"
        else if (state.extract)
            "extract"
        else if (units[0].inputs.len == 2)
            "merge"
        else
            "convert",
        if (units.len > 1) " of each input separately" else "",
    });
}

fn worker(job: *Job) void {
    for (job.units, 0..) |unit, i| {
        job.unit_index.store(i, .release);
        job.done.store(0, .release);
        job.total.store(0, .release);
        job.current_len.store(0, .release);
        const outcome = if (unit.folder)
            p2z.bridge.runFolder(
                job.overwrite,
                unit.output,
                unit.inputs[0],
                progressCallback,
                job,
                &job.error_buf,
            )
        else
            p2z.bridge.run(
                unit.mode,
                job.kind,
                job.overwrite,
                unit.output,
                unit.inputs,
                progressCallback,
                job,
                &job.error_buf,
            );
        job.outcomes[i] = outcome;
        if (outcome != .ok) break;
    }
    job.running.store(false, .release);
}

fn progressCallback(ctx: ?*anyopaque, progress: p2z.bridge.Progress) void {
    const job: *Job = @ptrCast(@alignCast(ctx.?));
    job.done.store(progress.done, .release);
    job.total.store(progress.total, .release);
    const n = @min(progress.current.len, job.current.len - 1);
    @memcpy(job.current[0..n], progress.current[0..n]);
    job.current[n] = 0;
    job.current_len.store(n, .release);
}

fn pollJob() void {
    const job = state.job orelse return;
    if (job.running.load(.acquire)) return;

    job.thread.join();

    const message = std.mem.sliceTo(&job.error_buf, 0);
    var all_ok = true;
    for (job.units, job.outcomes) |unit, outcome| {
        switch (outcome) {
            .ok => log("{s}", .{unit.output}),
            .cancelled => {
                all_ok = false;
                log("cancelled: {s}", .{unit.output});
            },
            .failed => {
                all_ok = false;
                log("failed: {s}: {s}", .{ unit.output, message });
            },
        }
    }
    if (all_ok) {
        // A successful run can still carry a note, e.g. that the input order was swapped.
        if (message.len > 0) log("{s}", .{message});
        log("Done: {d} output(s).", .{job.units.len});
    }

    for (job.units) |unit| {
        for (unit.inputs) |path| state.gpa.free(path);
        state.gpa.free(unit.inputs);
        state.gpa.free(unit.output);
    }
    state.gpa.free(job.outcomes);
    state.gpa.free(job.units);
    state.gpa.destroy(job);
    state.job = null;
    state.pending_overwrite = false;
}
