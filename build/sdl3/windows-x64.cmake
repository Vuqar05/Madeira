# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
# Keep Windows target selection when CMake regenerates an existing cache.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER "$ENV{MADEIRA_SDL3_MINGW}/x86_64-w64-mingw32-clang")
set(CMAKE_CXX_COMPILER "$ENV{MADEIRA_SDL3_MINGW}/x86_64-w64-mingw32-clang++")
set(CMAKE_RC_COMPILER "$ENV{MADEIRA_SDL3_MINGW}/x86_64-w64-mingw32-windres")
