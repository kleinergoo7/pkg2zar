# ps4-pkg2zar agent rules

Canonical policy for every coding agent in this repo. The user's current request wins, then this
file, then `docs/`.

## 1. Build and verify

- Build: `zig build && zig build test`. Everything, including the UI, is one Zig build.
- Run `zig fmt .` before `zig build` after every Zig change.
- Decide success from the process exit status, never from grepping compiler output. This machine
  emits German diagnostics (`Fehler:`), so an `error:` grep reports zero matches on a failed build.
- After a build that can fail, confirm the binary or library changed (mtime or hash). A stale
  artifact reads exactly like a successful build.
- Do not say "done", "fixed", or "works" without the command and its output. State what was run.
- The UI is Zig with dvui; there is no C++ build. If a native C dependency is added, say so in the change.

## 2. Language and boundaries

- New code is Zig, pinned to 0.17.0 (`build.zig.zon` `.minimum_zig_version`, checked by CI).
- Never write std or build APIs from memory; training data predates 0.17. Read
  `$(zig env | grep std_dir)` first.
- No C/C++ application files. The UI is `ui/main.zig`; the bridge still exports a C ABI for external callers, but the app itself calls it as a Zig module.
- The C ABI carries pointers, lengths, integers and status codes only. No allocators, slices,
  error unions or foreign types cross the boundary.
- Export with `export fn`; keep the Zig wrapper in `core/src/bridge.zig` in sync in the same change.

## 3. Errors must fail loudly

Silence is worse than a crash, because it produces a wrong archive that looks valid.

- No `catch |_| {}`, no `catch null`, no default value that hides a failure, no silent retry.
- No `catch unreachable` or `@panic` for anything a user or a pkg file can trigger. Use a named
  error and a message.
- Every failure returns a named error plus a message that names what failed and on which input:
  file path, entry path, header field, or byte offset. "Invalid pkg" alone is not a message.
- Refusals in `plan.zig` are data: error kind, offending file, offending field/path, and a
  user-facing sentence. The UI prints that sentence verbatim.
- Log at the point of failure before returning. The core does not write to stdout; it records the
  message in the result struct. The UI prints to the log pane and stderr.
- No partial output survives a failure: `.part` is deleted on error, cancel, and panic paths
  (`errdefer` or an equivalent guard in `export.zig`).
- Warnings are errors during development. If a validation cannot be performed, refuse; do not
  proceed with a guess.
- Never downgrade an error to a log line so the run can continue. A run either completes correctly
  or produces no output file.

## 4. Tests

- Every function with a branch, a loop, a parser, or arithmetic on file data gets a test.
- Zig tests live in `test` blocks beside the code; integration tests use `std.testing.allocator`.
- Real pkg fixtures: `P2Z_TEST_ROM` env var pointing at `test-rom/`. Tests skip with a clear
  message when it is unset, and never fail because a fixture is missing.
- Tests must never write into `test-rom/` or modify fixture files. Output goes to a temp dir.
- Cover the failure side of every refusal in §4 of the handoff: one test per named error.
- Test names state the behavior: `test "merge: update entry replaces base entry case-insensitively"`.
- Assert concrete values, not truthiness: magic bytes, entry counts, byte totals, hashes.
- A test that passes without the fixture present is not evidence. Say which fixture it needed.

## 5. Format code and untrusted input

- Fixed-width integers (`u8`..`u64`) for anything read from a file. Never `usize` for on-disk
  values.
- Bounds-check every read against the real file length before using it. Truncated input is the
  normal failure mode, not an edge case.
- On-disk layouts use `extern` or `packed struct` plus `comptime` size assertions.
- Comment every `@intCast`, `@ptrCast`, and `@bitCast` with why it is safe, naming the check that
  makes it valid.
- Named constants for offsets and flags (`pkg_image_offset = 0x410`), not inline hex.

## 6. Streaming and disk

- Never materialize an extracted game. Stream entry by entry.
- Temp usage is an in-memory index plus a few MiB of buffers. Cap any spill at 512 MiB and abort
  before filling the disk.
- Output is `name.zar.part`, renamed only after verification passes.
- Input pkg files are opened read-only. Never write next to them without the user choosing it.

## 7. Style

- Types PascalCase, functions camelCase, everything else snake_case.
- Short functions, early returns, shallow nesting.
- Comments explain why, citing the spec fact, offset, or bug; never what the line does.
- No magic numbers; no unrelated churn; match the surrounding code.
- Keep module boundaries: `pkg.zig` does not know about dvui or the UI; `zar.zig` does not parse pkgs.

## 8. Git and repository hygiene

- SPDX header on every source file: `GPL-3.0-or-later`, and attribution to the shadPS4 Emulator
  Project where code is ported.
- Never commit pkg files, game data, decryption keys, or `test-rom/`.
- Small commits, one reason each. Build fixes and behavior fixes land separately.
- Never force-push, never rewrite history without a backup branch.
- A workaround is labelled `WORKAROUND`, states why, and logs every trigger. Silent workarounds are
  bugs.

## 9. When unsure

- If an API, offset, or format fact cannot be verified, stop and say so. Do not guess a field or a
  signature.
- Prefer refusing an input over writing an archive that may be wrong.
