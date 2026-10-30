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
#define P2Z_ABI_VERSION 4u

#define P2Z_OK 0
#define P2Z_ERROR 1
#define P2Z_CANCELLED 2

/* Job mode for p2z_run. */
#define P2Z_MODE_AUTO 0   /* piece set by name, else 1 input converts, 2 merge */
#define P2Z_MODE_MERGE 1  /* force base + update */
#define P2Z_MODE_SINGLE 2 /* every input is one piece set */

/* `current` is the entry being written; it is not NUL-terminated. */
typedef void (*p2z_progress_fn)(void *ctx, uint64_t done, uint64_t total,
                                const char *current, size_t current_len);

uint32_t p2z_abi_version(void);

/* Sets the cancel flag for the running job. Safe to call from the UI thread. */
void p2z_cancel(void);

/* Runs one convert or merge job. Blocks until done.
 * Returns P2Z_OK, P2Z_ERROR or P2Z_CANCELLED. On error `err` receives a
 * user-facing message; on success it may hold a note (for example that the
 * inputs were swapped because the update was listed first).
 * Call from a worker thread. */
int p2z_run(int mode, int allow_overwrite, const char *output, const char *const *inputs,
            size_t input_count, p2z_progress_fn on_progress, void *ctx, char *err,
            size_t err_len);

#ifdef __cplusplus
}
#endif

#endif /* P2Z_H */
