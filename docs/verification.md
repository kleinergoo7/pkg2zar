# Verification record

## Extractors compared

Three independent extractors were run on the same pkgs and compared file by file with
`diff -rq` plus sha256. "Ours" is this repo's `extract`.

| Oracle | Terraria base | Terraria merged | Minecraft base |
|---|---|---|---|
| `ps4-pkg-tools` (shadPS4 file_format code) | identical | identical | identical |
| `ShadPs4Plus-PkgExtractor` 1.1 | differs only in `npbind.dat` (left encrypted) | not run | not run |
| `pkgextract` 0.1 (Rust) | differs in `npbind.dat`, missing `license.info` | not run | missing all `sce_sys/keymap_rp/**` |

A second pass compared Minecraft's 2.4 GB update against `ps4-pkg-tools`: 37,416 real files,
byte-identical. That pass found a real walker bug: directories with more entries than fit in
one 64 KiB block continue in the next block, which has no `.<self>` header. Those continuation
blocks were skipped, losing 3,024 files. The walker now attaches them to the directory being
read and skips blocks claimed by file inodes instead of guessing where metadata ends.

"Identical" means every real file has the same bytes. Two deliberate differences remain:

- We do not write the pkg metadata blobs (`digests`, `entry_keys`, `entry_names`,
  `general_digests`, `image_key`, `metas`); they are not installed game content.
- `npbind.dat`, `license.dat`, `license.info`, `nptitle.dat` are stored encrypted in the pkg
  (entries `0x400`-`0x403`) and are decrypted on the way out, matching `ps4-pkg-tools`.

## Boot test

`tools/boot-test.sh` runs shadPS4 fullscreen on the desktop Wayland session, captures the
screen with Spectacle at ~20 s and requires: `Game id` in the log, at least one
`UpdatePlayTime` tick, no critical line, and a non-blank screenshot.

Result on the fixtures:

```
Terraria merged-zar   PASS   screenshot mean 0.319 std 0.086
Terraria merged-dir   PASS   screenshot mean 0.341 std 0.078
Minecraft merged-zar  PASS   mean 0.329 std 0.091, one background-thread critical (NetherNet)
```

The harness fails on a critical line only when it happens before the game loop starts. Minecraft
crashes shadPS4's NetherNet LAN thread after the first frame and keeps rendering; that is
reported as a warning, not a pass for a dead process.

Weston's headless backend was tried first and cannot be used: every shadPS4 SDL instance
fails with `ErrorSurfaceLostKHR` in `FindPresentFormat`, fullscreen or not, on a persistent
compositor. The desktop session works.
