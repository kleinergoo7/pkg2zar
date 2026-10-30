/* SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef P2Z_H
#define P2Z_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must match ABI_VERSION in core/src/bridge.zig. */
#define P2Z_ABI_VERSION 1u

#define P2Z_OK 0
#define P2Z_ERROR 1
#define P2Z_CANCELLED 2

typedef void (*p2z_progress_fn)(void *ctx, uint64_t done, uint64_t total);

uint32_t p2z_abi_version(void);

/* Sets the cancel flag for the running job. Safe to call from the UI thread. */
void p2z_cancel(void);

/* Runs one convert (one input) or merge (two inputs). Blocks until done.
 * Returns P2Z_OK, P2Z_ERROR or P2Z_CANCELLED; on error `err` receives a
 * user-facing message. Call from a worker thread. */
int p2z_run(const char *output, const char *const *inputs, size_t input_count,
            p2z_progress_fn on_progress, void *ctx, char *err, size_t err_len);

#ifdef __cplusplus
}
#endif

#endif /* P2Z_H */
