// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub const pkg = @import("pkg.zig");
pub const crypto = @import("crypto.zig");

/// C ABI revision. Bumped whenever a signature in core/src/p2z.h changes.
pub const abi_version: u32 = 1;

export fn p2z_abi_version() u32 {
    return abi_version;
}
pub const pfs = @import("pfs.zig");
pub const unpack = @import("unpack.zig");
pub const zar = @import("zar.zig");
pub const pieces = @import("pieces.zig");
pub const source = @import("source.zig");
pub const plan = @import("plan.zig");
pub const exporter = @import("export.zig");

test {
    std.testing.refAllDecls(@This());
}
