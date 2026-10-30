# ps4-pkg2zar

Converts PS4 `.pkg` files into shadPS4 `.zar` archives, and optionally merges a base game with its
update into one archive.

Status: converts and merges real pkgs end to end, verified against the reference ZArchive
reader. Single pkg → `.zar`, base + update → one `.zar` with the update winning conflicts.
Split piece sets (`prefix_0.pkg`, `prefix_1.pkg`, ...) are accepted.

## Build

Requires Zig 0.17.0. The UI uses [dvui](https://github.com/david-vanderson/dvui) with the SDL3 backend; SDL is built as a Zig dependency, so there is nothing else to install.

```sh
zig build
./zig-out/bin/ps4-pkg2zar
```

One command builds the core, the tools and the UI. The build is Zig only.

```sh
zig build             # debug binaries in zig-out/bin
zig build run         # start the app
zig build test        # unit tests
zig build check       # formatting check on the Zig sources
zig build --release=safe   # binaries for distribution
```

Zig must be 0.17.0. If another version comes first on `PATH`, put 0.17 first.

## Usage

GUI: drop one pkg (convert) or two (merge, roles detected automatically), choose Archive or
Extract, pick the output, press Convert. The output name is built from `param.sfo` and the
header: `Terraria (CUSA00740) v01.00.zar`, plus ` - merged`, ` - base` or ` - update` where it
matters, so names are stable regardless of the source file names. Cancel leaves nothing behind. Extract writes into
`<out>.part` and replaces the destination only after every file is size-checked.

Headless, same code path as the GUI button:

```sh
zig-out/bin/export out.zar base.pkg [update.pkg]
zig-out/bin/extract out-dir base.pkg [update.pkg]
zig-out/bin/plan  base.pkg [update.pkg]     # preflight and merge plan, writes nothing
zig-out/bin/listfiles base.pkg [piece...]   # file tree of a pkg or piece set
zig-out/bin/pkginfo base.pkg                # header fields
```

An offscreen UI self-test drives the real widgets:

```sh
QT_QPA_PLATFORM=offscreen ./build/ps4-pkg2zar --ui-selftest convert out.zar base.pkg
QT_QPA_PLATFORM=offscreen ./build/ps4-pkg2zar --ui-selftest cancel  out.zar base.pkg update.pkg
```

Modes: `convert`, `merge`, `swap`, `cancel`, `separate`, `extract`, `name`, `name-merged`. It exits 0 on pass and prints the log on failure.

Merge detects roles by content, not by list order: listing the update first swaps the two and
logs a note.

## Layout

- `core/src/` — Zig core, built as a static library behind a C ABI (`core/src/bridge.zig`)
- `ui/main.zig` — dvui front end (SDL3 backend); all work runs through `core/src/bridge.zig`
- `tools/` — pkginfo, listfiles, plan, export, extract
- `docs/debt.md` — running debt ledger

## Notes

- PlayGo state is not modelled. A finished `.zar` is a fully installed game, so
  `sce_sys/playgo-chunk.dat` is copied as an ordinary file.
- Delta updates, retail PSN passcodes, and DLC install layout are refused, not handled.
- Test fixtures are not committed. Point `P2Z_TEST_ROM` at a directory of `.pkg` files to run
  real-data tests.

## License

GPL-3.0-or-later. See `NOTICE` for the origin of ported code.
