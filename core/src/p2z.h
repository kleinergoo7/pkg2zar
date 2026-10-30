/* SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef P2Z_H
#define P2Z_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must match abi_version in core/src/root.zig. */
#define P2Z_ABI_VERSION 1u

uint32_t p2z_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* P2Z_H */
