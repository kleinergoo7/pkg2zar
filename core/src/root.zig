// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

/// C ABI revision. Bumped whenever a signature in core/src/p2z.h changes.
pub const abi_version: u32 = 1;

export fn p2z_abi_version() u32 {
    return abi_version;
}
