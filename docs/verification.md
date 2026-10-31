# Verification record

## Extractors compared

Three independent extractors were run on the same pkgs and compared file by file with
`diff -rq` plus sha256. "Ours" is this repo's `extract`.

| Oracle | Terraria base | Terraria merged | Minecraft base |
|---|---|---|---|
| `ps4-pkg-tools` (shadPS4 file_format code) | identical | identical | identical |
| `ShadPs4Plus-PkgExtractor` 1.1 (mandated oracle) | every file identical except 4 trailing bytes of `npbind.dat` | same | not run |
| `pkgextract` 0.1 (Rust) | differs in `npbind.dat`, missing `license.info` | not run | missing all `sce_sys/keymap_rp/**` |

A second pass compared Minecraft's 2.4 GB update against `ps4-pkg-tools`: 37,416 real files,
byte-identical. That pass found a real walker bug: directories with more entries than fit in
one 64 KiB block continue in the next block, which has no `.<self>` header. Those continuation
blocks were skipped, losing 3,024 files. The walker now attaches them to the directory being
read and skips blocks claimed by file inodes instead of guessing where metadata ends.

Extracted-vs-extracted comparison with the mandated oracle, sha256 per file, Terraria base,
update and merged: 34 of 35 real files byte-identical, plus `license.dat`, `license.info` and
`nptitle.dat` correct. The one difference is the last 4 bytes of `npbind.dat` (532 bytes, not a
multiple of 16). Its source shows why: `extractor` builds `std::span<u8> cipherNp(data.data(),
msize)` where `data` holds only `entry.size` bytes and `msize` is rounded up, so 12 bytes past
the buffer are read and decrypted. Those 4 plaintext bytes therefore depend on heap contents.

`"Identical" means every real file has the same bytes. Two deliberate differences remain:

- We do not write the pkg metadata blobs (`digests`, `entry_keys`, `entry_names`,
  `general_digests`, `image_key`, `metas`); they are not installed game content.
- `npbind.dat`, `license.dat`, `license.info`, `nptitle.dat` are stored encrypted in the pkg
  (entries `0x400`-`0x403`) and are decrypted on the way out, matching `ps4-pkg-tools`.

## Byte parity with the mandated oracles

Two references, one per half of the pipeline.

**Extraction** — `ShadPs4Plus-PkgExtractor-1.1-linux.AppImage` (AzaharPlus/shadPS4Plus,
`extractor/main.cpp`). It writes every pkg entry as `sce_sys/<name>` from its 611-entry table,
or `sce_sys/<decimal id>` when the id is unknown, plus the PFS tree. `core/src/pkg_names.zig` is
that table; `source.sceFiles` writes every entry. `diff -r` against the oracle tree is silent on
Terraria base, Terraria update and Minecraft base, except `sce_sys/npbind.dat`.

`npbind.dat` is 532 bytes, not a multiple of 16. The oracle rounds the buffer up to 544 and
decrypts 12 bytes past its own allocation, so its last four plaintext bytes come from
uninitialised heap. Ours pads with zeros; that value matches `ps4-pkg-tools` (shadPS4's
file_format code) and is the only defensible decryption. The exception cannot be removed without
reproducing undefined behaviour.

**.zar** — the writer shadPS4 pins: `shadps4-emu/shadPS4` submodule `externals/zarchive` =
`shadexternals/ZArchive@965b66c8d67b6b7e30fd63b3b75aa91a99ff303b`, built with zstd 1.5.7.

The reference CLI packs a folder in `readdir` order, which is filesystem-specific: the same tree
packed under `/tmp` and under `/home` differs at byte 8. A pkg-only converter cannot know that
order, so the comparison feeds the reference writer an explicit order instead:

1. `zig-out/bin/plan --manifest base.pkg [update.pkg]` prints the writer call sequence
   (`d <path>` / `f <path>`) in the exact order `export` uses.
2. A 60-line driver links `libzarchive.a` from that commit and replays the manifest:
   `MakeDir` for `d`, `StartNewFile` + 64 KiB `AppendData` for `f`, then `Finalize`.
3. `cmp ours.zar driver.zar` must be silent.

Results, zstd 1.5.7, `cmp` exit 0 for all four:

| Input | Archive |
|---|---|
| Terraria base | 93,152,845 bytes |
| Terraria update | 262,058,217 bytes |
| Terraria base+update merged | 262,146,613 bytes |
| Minecraft base | 169,846,277 bytes |

Two writer differences were found and fixed this way:

- the footer's compressed-data size is the offset *before* the 8-byte padding;
- the name table deduplicates case-sensitively (`Default.png` and `default.png` are two entries),
  while directory lookups stay case-insensitive.
