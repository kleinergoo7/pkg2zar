# ps4-pkg2zar

Converts PS4 `.pkg` files into shadPS4 `.zar` archives, and optionally merges a base game with its
update into one archive.

Status: converts and merges real pkgs end to end, verified against the reference ZArchive
reader. Single pkg → `.zar`, base + update → one `.zar` with the update winning conflicts.
Split piece sets (`prefix_0.pkg`, `prefix_1.pkg`, ...) are accepted.

## Build

Requires Zig 0.16.0, CMake 3.21+, Qt 6 Widgets.

```sh
cmake -S . -B build
cmake --build build
./build/ps4-pkg2zar
```

Zig only:

```sh
zig build
zig build test
```

## Usage

GUI: drop one pkg (convert) or two (merge, base then update), pick the output, press Convert.
Cancel leaves no file behind.

Headless, same code path as the GUI button:

```sh
zig-out/bin/export out.zar base.pkg [update.pkg]
zig-out/bin/plan  base.pkg [update.pkg]     # preflight and merge plan, writes nothing
zig-out/bin/listfiles base.pkg [piece...]   # file tree of a pkg or piece set
zig-out/bin/pkginfo base.pkg                # header fields
```

The Qt binary also accepts `ps4-pkg2zar --run out.zar base.pkg [update.pkg]`.

An offscreen UI self-test drives the real widgets:

```sh
QT_QPA_PLATFORM=offscreen ./build/ps4-pkg2zar --ui-selftest convert out.zar base.pkg
QT_QPA_PLATFORM=offscreen ./build/ps4-pkg2zar --ui-selftest cancel  out.zar base.pkg update.pkg
```

Modes: `convert`, `merge`, `cancel`, `separate`. It exits 0 on pass and prints the log on failure.

## Layout

- `core/src/` — Zig core, built as a static library behind a C ABI (`p2z.h`)
- `ui/` — Qt shell, the only C++ in the project
- `tools/` — pkginfo, listfiles, plan, export
- `docs/debt.md` — running debt ledger

## Notes

- PlayGo state is not modelled. A finished `.zar` is a fully installed game, so
  `sce_sys/playgo-chunk.dat` is copied as an ordinary file.
- Delta updates, retail PSN passcodes, and DLC install layout are refused, not handled.
- Test fixtures are not committed. Point `P2Z_TEST_ROM` at a directory of `.pkg` files to run
  real-data tests.

## License

GPL-3.0-or-later. See `NOTICE` for the origin of ported code.
