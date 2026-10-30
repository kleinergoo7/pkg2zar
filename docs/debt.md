# Debt ledger

One line per item: `path: debt — why it exists — exit condition`.
A debt item with no exit condition does not belong in this repo.

| Item | Why it exists | Exit condition |
|---|---|---|
| libzstd | Zig 0.17 std has no zstd compressor | Zig gains a compressor, or raw-block `.zar` output becomes acceptable |
| `bridge.zig` exports next to Zig wrappers | the C ABI predates the Zig UI; external tools may still call it | delete the `export fn` layer once no external caller exists |
| dvui + bundled SDL | the UI needs a window, input and native dialogs | a Zig-native windowing layer in std, or the UI disappears |
