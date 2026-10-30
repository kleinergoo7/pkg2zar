# Debt ledger

One line per item: `path: debt — why it exists — exit condition`.
A debt item with no exit condition does not belong in this repo.

| Item | Why it exists | Exit condition |
|---|---|---|
| zstd 1.5.7 (Zig package) | Zig 0.17 std has no zstd compressor, and only Linux ships a system libzstd | Zig gains a compressor, or raw-block `.zar` output becomes acceptable |
| dvui, SDL3 on Linux/macOS, DX11 on Windows | the UI needs a window, input and native dialogs | a Zig-native windowing layer in std, or the UI disappears |
