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
