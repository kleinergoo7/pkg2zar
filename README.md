# ps4-pkg2zar

Converts PS4 `.pkg` files into shadPS4 `.zar` archives, and optionally merges a base game with its
update into one archive.

Status: skeleton. The core currently exposes only its ABI version. No pkg parsing, merge, or
archive writing exists yet.

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

## Layout

- `core/src/` — Zig core, built as a static library behind a C ABI (`p2z.h`)
- `ui/` — Qt shell, the only C++ in the project
- `docs/debt.md` — running debt ledger

## Notes

- PlayGo state is not modelled. A finished `.zar` is a fully installed game, so
  `sce_sys/playgo-chunk.dat` is copied as an ordinary file.
- Delta updates, retail PSN passcodes, and DLC install layout are refused, not handled.
- Test fixtures are not committed. Point `P2Z_TEST_ROM` at a directory of `.pkg` files to run
  real-data tests.

## License

GPL-3.0-or-later. See `NOTICE` for the origin of ported code.
