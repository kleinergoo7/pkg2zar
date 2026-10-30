# Debt ledger

One line per item: `path: debt — why it exists — exit condition`.
A debt item with no exit condition does not belong in this repo.

| Item | Why it exists | Exit condition |
|---|---|---|
| `ui/*.cpp` Qt shell | Qt 6 has no stable Zig binding | Fixed budget of about 500 lines; shrink only, never grow |
| `core/src/p2z.h` | The C ABI has no Zig-native equivalent | Generated from Zig `export fn` signatures once that is stable |
| libzstd | Zig 0.17 std has no zstd compressor; it is linked for `.zar` output | Zig gains a compressor, or raw-block output becomes acceptable |
