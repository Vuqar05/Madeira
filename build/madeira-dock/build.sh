#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Build Madeira Dock (madeira-dock) as a stripped x86-64 PE and stage
# it in the app bundle with its notices:
#   app/Madeira/arm64ec-windows/dockhost.exe
#   app/Madeira/arm64ec-windows/dock-notices.txt
# SDL3.dll and sdl3-notices.txt are also built/staged by this entry point.
# These are build outputs (gitignored). The app starts dockhost.exe as
# C:\windows\system32\dockhost.exe; without it, Madeira Dock stays hidden.
#
# Usage: build/madeira-dock/build.sh [--check]
#   --check  also build and run Dock's own unit tests with the host compiler
#            (madeira-dock/tools/check.sh; needs cc with ASan/UBSan).
# LLVM_MINGW=<dir with x86_64-w64-mingw32-clang> overrides the toolchain.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$REPO_ROOT/madeira-dock"
MINGW="${LLVM_MINGW:-$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
CC="$MINGW/x86_64-w64-mingw32-clang"
OUT="$REPO_ROOT/app/Madeira/arm64ec-windows"

[ -f "$SRC/src/main.c" ] || { echo "madeira-dock is missing: git submodule update --init madeira-dock" >&2; exit 1; }
[ -x "$CC" ] || { echo "missing cross compiler: $CC (set LLVM_MINGW)" >&2; exit 1; }

# A directly built app must have the same controller dependency as the runtime
# component build. Without x64 SDL, Steam cannot enumerate the virtual pad.
bash "$REPO_ROOT/build/sdl3/build.sh"
[ -s "$OUT/SDL3.dll" ] && [ -s "$OUT/sdl3-notices.txt" ] || {
    echo "SDL3 runtime dependency was not staged" >&2; exit 1;
}

if [ "${1:-}" = "--check" ]; then
    (cd "$SRC" && bash tools/check.sh)
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Explicit opt-in for the bounded revision/mapping experiment. Ordinary builds
# cannot execute the diagnostic command, even if a fixture is present.
PROBE_DEFINE=-DSH_STEAM_INPUT_REVISION_PROBE=0
if [ "${DOCK_REVISION_PROBE:-0}" = 1 ]; then
    PROBE_DEFINE=-DSH_STEAM_INPUT_REVISION_PROBE=1
fi

LOCAL_APPLY_DEFINE=-DSH_STEAM_INPUT_LOCAL_APPLY=1
if [ "${DOCK_LOCAL_APPLY:-1}" = 0 ]; then
    LOCAL_APPLY_DEFINE=-DSH_STEAM_INPUT_LOCAL_APPLY=0
fi

# Same flags as Dock's own tools/build.sh: warnings are errors, the runtime is
# linked statically (its notices go into dock-notices.txt) and symbols are
# stripped. -Wl,--no-insert-timestamp keeps the output reproducible.
"$CC" "$PROBE_DEFINE" "$LOCAL_APPLY_DEFINE" -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type \
    -static -Wl,--strip-all -Wl,--no-insert-timestamp \
    -o "$TMP/dockhost.exe" "$SRC"/src/*.c -ladvapi32 -luser32

section() { printf '\n\n==== %s ====\n\n' "$1"; }
{
    cat "$SRC/LICENSE"
    printf '\nCorresponding source: https://github.com/125hz/madeira-dock (commit %s)\n' \
        "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    section 'LICENSE-EXCEPTION.md (Madeira Converter Exception)'
    cat "$SRC/LICENSE-EXCEPTION.md"
    section 'COPYING (GNU General Public License, version 3)'
    cat "$SRC/COPYING"
    section 'MinGW-w64 runtime notice (statically linked runtime)'
    cat "$SRC/notices/MinGW-w64-runtime.txt"
    section 'LLVM runtime notice'
    cat "$SRC/notices/LLVM.txt"
} > "$TMP/dock-notices.txt"

mkdir -p "$OUT"
cp "$TMP/dockhost.exe" "$TMP/dock-notices.txt" "$OUT/"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$OUT/dockhost.exe"; else sha256sum "$OUT/dockhost.exe"; fi
ls -la "$OUT/dockhost.exe" "$OUT/dock-notices.txt"
