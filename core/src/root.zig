// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const pkg = @import("pkg.zig");
pub const crypto = @import("crypto.zig");

pub const pfs = @import("pfs.zig");
pub const unpack = @import("unpack.zig");
pub const zar = @import("zar.zig");
pub const pieces = @import("pieces.zig");
pub const source = @import("source.zig");
pub const bridge = @import("bridge.zig");
pub const plan = @import("plan.zig");
pub const exporter = @import("export.zig");

test {
    std.testing.refAllDecls(@This());
}

comptime {
    // Force the C ABI exports to be analyzed when the library is built.
    _ = bridge;
}
