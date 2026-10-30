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
#define P2Z_ABI_VERSION 7u

#define P2Z_OK 0
#define P2Z_ERROR 1
#define P2Z_CANCELLED 2

/* Job mode for p2z_run. */
#define P2Z_MODE_AUTO 0   /* piece set by name, else 1 input converts, 2 merge */
#define P2Z_MODE_MERGE 1  /* force base + update */
#define P2Z_MODE_SINGLE 2 /* every input is one piece set */

/* Output kind for p2z_run. */
#define P2Z_KIND_ARCHIVE 0 /* write out.zar */
#define P2Z_KIND_EXTRACT 1 /* extract into out/ */

/* `current` is the entry being written; it is not NUL-terminated. */
typedef void (*p2z_progress_fn)(void *ctx, uint64_t done, uint64_t total,
                                const char *current, size_t current_len);

uint32_t p2z_abi_version(void);

/* Reads the display name, title id, version and patch flag without decrypting.
 * Buffers receive NUL-terminated strings. Returns 0 on success, 1 with a message in `err`. */
int p2z_probe(const char *path, char *title, size_t title_len, char *title_id, size_t id_len,
              char *version, size_t version_len, int *is_patch, char *err, size_t err_len);

/* Output name roles for p2z_output_name. */
#define P2Z_ROLE_SINGLE 0
#define P2Z_ROLE_MERGED 1
#define P2Z_ROLE_BASE 2
#define P2Z_ROLE_UPDATE 3

/* Builds the default output name (adds .zar unless extract is non-zero). Empty title,
 * title_id or version are skipped. Returns 0 on success. */
int p2z_output_name(int role, const char *title, const char *title_id, const char *version,
                    int extract, char *out, size_t out_len);

/* Sets the cancel flag for the running job. Safe to call from the UI thread. */
void p2z_cancel(void);

/* Runs one convert or merge job. Blocks until done.
 * Returns P2Z_OK, P2Z_ERROR or P2Z_CANCELLED. On error `err` receives a
 * user-facing message; on success it may hold a note (for example that the
 * inputs were swapped because the update was listed first).
 * Call from a worker thread. */
int p2z_run(int mode, int kind, int allow_overwrite, const char *output,
            const char *const *inputs, size_t input_count, p2z_progress_fn on_progress,
            void *ctx, char *err, size_t err_len);

#ifdef __cplusplus
}
#endif

#endif /* P2Z_H */
