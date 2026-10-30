#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Boot test: runs shadPS4 fullscreen on the desktop session and checks that the game really starts.
# Not part of `zig build test`; it needs the emulator, a few hundred MB of input and minutes.
#
#   P2Z_TEST_PKG=base.pkg P2Z_TEST_UPDATE=update.pkg tools/boot-test.sh [--case NAME] [--keep]
#
# Environment:
#   P2Z_SHADPS4      emulator binary or AppRun (default /tmp/opencode/shadps4/squashfs-root/AppRun)
#   P2Z_TEST_PKG     base pkg
#   P2Z_TEST_UPDATE  update pkg (needed for the merge cases)
#   P2Z_BOOT_ROOT    work dir (default /tmp/opencode/p2z-boot)
#
# Pass criteria per case:
#   1. log has "Game id: <title id>"
#   2. the emulator is still running when the screenshot is taken
#   3. play-time ticks and background-thread crashes are reported as warnings
#
# A background-thread crash is not treated as failure: shadPS4 crashes the same way on an
# install produced by ps4-pkg-tools, so the archive is not the cause.
#   4. a Spectacle screenshot at ~60s is a real frame (mean and stddev above thresholds)

set -u -o pipefail

ROOT="${P2Z_BOOT_ROOT:-/tmp/opencode/p2z-boot}"
SHADPS4="${P2Z_SHADPS4:-/tmp/opencode/shadps4/squashfs-root/AppRun}"
BASE="${P2Z_TEST_PKG:-}"
UPDATE="${P2Z_TEST_UPDATE:-}"
KEEP=0
ONLY_CASE=""

while (($# > 0)); do
    case "$1" in
        --case) ONLY_CASE="${2:-}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$BASE" ]]; then
    echo "P2Z_TEST_PKG is not set (path to a base pkg)" >&2
    exit 2
fi
if [[ ! -x "$SHADPS4" ]]; then
    echo "shadPS4 not found at $SHADPS4 (set P2Z_SHADPS4)" >&2
    exit 2
fi
for tool in spectacle identify; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

# Wayland session, taken from the environment or from the running compositor.
if [[ -z "${WAYLAND_DISPLAY:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
    kwin_pid=$(pgrep -u "$(id -u)" -n kwin_wayland || true)
    if [[ -n "$kwin_pid" ]]; then
        while IFS= read -r line; do export "$line"; done < <(
            tr '\0' '\n' < "/proc/$kwin_pid/environ" 2>/dev/null |
                grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR)=')
    fi
fi
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "no Wayland session found; run this from the desktop session" >&2
    exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT="$HERE/zig-out/bin/export"
EXTRACT="$HERE/zig-out/bin/extract"
for tool in "$EXPORT" "$EXTRACT"; do
    [[ -x "$tool" ]] || { echo "missing $tool; run zig build first" >&2; exit 2; }
done

mkdir -p "$ROOT"
LOG="$ROOT/boot-test.log"
: > "$LOG"

pass=0
fail=0

say() { echo "$*" | tee -a "$LOG"; }

# The game is made fullscreen so the full-screen screenshot shows the game, not the desktop.
check_case() {
    local name="$1" target="$2"
    local dir="$ROOT/$name"
    local log="$dir/shad.log"
    local shots="$dir/shots"

    say "== $name"
    say "   target: $target"
    rm -rf "$dir"
    mkdir -p "$dir" "$shots"

    export HOME="$dir/home"
    export XDG_PICTURES_DIR="$shots"
    mkdir -p "$HOME"
    unset DISPLAY VK_ICD_FILENAMES

    timeout -k 3 110 "$SHADPS4" -g "$target" --fullscreen true >"$log" 2>&1 &
    local runner=$!
    # Fail fast when the emulator never even reads the title.
    for _ in $(seq 40); do
        grep -aq "Game id: " "$log" && break
        kill -0 "$runner" 2>/dev/null || break
        sleep 0.5
    done
    # Minecraft needs a minute of loading before the first frame; smaller titles are faster
    # but the same window is harmless.
    sleep 60
    local first="$shots/frame.png"
    spectacle -f -b -n -o "$first" >/dev/null 2>&1 || true
    sleep 30
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true

    local problems=()
    grep -aq "Game id: " "$log" || problems+=("no Game id line")
    kill -0 "$runner" 2>/dev/null || problems+=("emulator died before the screenshot")

    local ticks critical
    ticks=$(grep -ac "UpdatePlayTime" "$log")
    ((ticks >= 1)) || say "   warning: no play-time tick yet (still loading?)"
    critical=$(grep -aciE "\[Debug\] <Critical>|Unreachable code" "$log")
    ((critical > 0)) && say "   warning: $critical critical line(s) in background threads"

    if [[ -n "$first" ]]; then
        local stats mean std
        stats=$(identify -format "%[fx:mean] %[fx:standard_deviation]" "$first" 2>/dev/null)
        mean=${stats%% *}
        std=${stats##* }
        say "   screenshot: mean=${mean:-?} std=${std:-?}"
        awk -v m="${mean:-0}" -v s="${std:-0}" 'BEGIN { exit !(m > 0.02 && s > 0.02) }' ||
            problems+=("screenshot is blank")
    else
        problems+=("no screenshot was taken")
    fi


    if ((${#problems[@]} > 0)); then
        say "   FAIL: ${problems[*]}"
        say "   log: $log"
        fail=$((fail + 1))
        return 1
    fi
    say "   PASS"
    pass=$((pass + 1))
    return 0
}

prepare_zar() {
    local out="$ROOT/merged.zar"
    if [[ ! -f "$out" ]]; then
        say "building $out" >&2
        "$EXPORT" "$out" "$BASE" "$UPDATE" >"$ROOT/export.log" 2>&1 || return 1
    fi
    echo "$out"
}

prepare_dir() {
    local out="$ROOT/merged"
    if [[ ! -d "$out" ]]; then
        say "extracting $out" >&2
        rm -rf "$out"
        "$EXTRACT" "$out" "$BASE" "$UPDATE" >"$ROOT/extract.log" 2>&1 || return 1
    fi
    echo "$out"
}

run_case() {
    local name="$1"
    if [[ -n "$ONLY_CASE" && "$ONLY_CASE" != "$name" ]]; then
        return 0
    fi
    case "$name" in
        merged-zar)
            [[ -n "$UPDATE" ]] || { say "== merged-zar: skipped, P2Z_TEST_UPDATE is not set"; return 0; }
            local target
            target=$(prepare_zar) || { say "== merged-zar: FAIL: could not build the archive"; fail=$((fail + 1)); return 0; }
            check_case merged-zar "$target"
            ;;
        merged-dir)
            [[ -n "$UPDATE" ]] || { say "== merged-dir: skipped, P2Z_TEST_UPDATE is not set"; return 0; }
            local target
            target=$(prepare_dir) || { say "== merged-dir: FAIL: could not extract"; fail=$((fail + 1)); return 0; }
            check_case merged-dir "$target"
            ;;
        base-dir)
            local out="$ROOT/base"
            [[ -d "$out" ]] || "$EXTRACT" "$out" "$BASE" >"$ROOT/extract-base.log" 2>&1
            check_case base-dir "$out"
            ;;
        *) say "unknown case $name"; fail=$((fail + 1)) ;;
    esac
}

run_case merged-zar
run_case merged-dir

if ((!KEEP)); then
    rm -rf "$ROOT/merged" "$ROOT/base"
fi

say ""
say "boot test: $pass passed, $fail failed"
((fail == 0))
