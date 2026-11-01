#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Build an x86-64 SDL3.dll for Valve's 64-bit client in Madeira Dock and
# stage it with its licence:
#   app/Madeira/arm64ec-windows/SDL3.dll
#   app/Madeira/arm64ec-windows/sdl3-notices.txt
# Both are build outputs (gitignored).
#
# Why: steamclient64.dll reads controllers through SDL3.dll
# ("CHIDDeviceListSDL(): Couldn't load SDL3.dll, not enumerating devices").
# The pinned January client ships only a 32-bit SDL3.dll, for steam.exe, so
# the 64-bit client in dockhost.exe sees no controller. This is upstream SDL
# at the commit Valve's copy reports (SDL-release-3.4.0-98-gb1362f8a4),
# unmodified. Steam loads its own folder's copy first; that one fails
# (wrong architecture) and the search by name then finds this one next to
# dockhost.exe in C:\windows\system32. See docs/STEAM_INPUT.md.
#
# Usage: build/sdl3/build.sh
# LLVM_MINGW=<dir with x86_64-w64-mingw32-clang> overrides the toolchain.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="${LLVM_MINGW:-$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
OUT="$REPO_ROOT/app/Madeira/arm64ec-windows"
COMMIT=b1362f8a427b32e01df19b48c8dd4b6599d6cc6d
WORK="${SDL3_WORK:-$REPO_ROOT/build/sdl3/work}"

[ -x "$MINGW/x86_64-w64-mingw32-clang" ] || { echo "missing cross compiler in $MINGW (set LLVM_MINGW)" >&2; exit 1; }

if [ ! -d "$WORK/src/.git" ]; then
    mkdir -p "$WORK"
    git clone -q --filter=blob:none https://github.com/libsdl-org/SDL.git "$WORK/src"
fi
git -C "$WORK/src" checkout -q "$COMMIT"
[ "$(git -C "$WORK/src" rev-parse HEAD)" = "$COMMIT" ] || { echo "SDL is not at $COMMIT" >&2; exit 1; }

cmake -S "$WORK/src" -B "$WORK/build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$MINGW/x86_64-w64-mingw32-clang" \
    -DCMAKE_CXX_COMPILER="$MINGW/x86_64-w64-mingw32-clang++" \
    -DCMAKE_RC_COMPILER="$MINGW/x86_64-w64-mingw32-windres" \
    -DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=ON -DSDL_STATIC=OFF \
    -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF >/dev/null
ninja -C "$WORK/build" >/dev/null
"$MINGW/llvm-strip" -o "$OUT/SDL3.dll" "$WORK/build/SDL3.dll"
{
    echo "SDL3.dll: Simple DirectMedia Layer, upstream commit $COMMIT"
    echo "(release-3.4.0-98), unmodified. https://github.com/libsdl-org/SDL"
    echo
    cat "$WORK/src/LICENSE.txt"
} > "$OUT/sdl3-notices.txt"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$OUT/SDL3.dll"; else sha256sum "$OUT/SDL3.dll"; fi
