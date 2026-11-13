#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Reject a Dock app bundle missing Steam Input's required runtime fixes.

These capability checks supplement the runtime source/build manifests. They do
not certify general source freshness or prove input delivery to a game.
"""
import argparse
from pathlib import Path
import plistlib
import struct


def check(bundle):
    folder = bundle / 'arm64ec-windows'
    if not (folder / 'dockhost.exe').exists():
        return  # Dock is optional.
    for name in ['dockhost.exe', 'dock-notices.txt', 'SDL3.dll', 'sdl3-notices.txt']:
        file = folder / name
        if not file.is_file() or not file.stat().st_size:
            raise ValueError('missing Dock runtime dependency: ' + name)
    if b'MSICTX01' not in (folder / 'dockhost.exe').read_bytes():
        raise ValueError('Dock lacks game-default source context; rebuild build/madeira-dock/build.sh')
    # A 32-bit game exits before its loader can report an error if the i386
    # runtime folder was left empty in a local build. Validate both halves of
    # WoW64 before installation, not just the Steam controller dependencies.
    for directory, machine, names in [
        ('i386-windows', 0x14c, ['ntdll.dll', 'kernel32.dll', 'kernelbase.dll', 'win32u.dll']),
        ('aarch64-windows', 0xaa64, ['ntdll.dll', 'wow64.dll', 'wow64win.dll', 'xtajit.dll']),
    ]:
        for name in names:
            path = bundle / directory / name
            if not path.is_file():
                raise ValueError('missing game runtime dependency: ' + directory + '/' + name)
            with path.open('rb') as file:
                header = file.read(64)
                if len(header) != 64 or header[:2] != b'MZ':
                    raise ValueError('invalid game runtime dependency: ' + directory + '/' + name)
                file.seek(struct.unpack_from('<I', header, 0x3c)[0])
                pe = file.read(6)
            if len(pe) != 6 or pe[:4] != b'PE\0\0' or struct.unpack_from('<H', pe, 4)[0] != machine:
                raise ValueError('wrong architecture for game runtime dependency: ' + directory + '/' + name)
    data = (folder / 'SDL3.dll').read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('SDL3.dll is not a PE file')
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    if offset + 24 > len(data) or data[offset:offset+4] != b'PE\0\0' or struct.unpack_from('<H', data, offset+4)[0] != 0x8664:
        raise ValueError('Steam Input requires x64 SDL3.dll')
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    native = bundle / 'Madeira.debug.dylib'
    if not native.is_file():
        native = bundle / info['CFBundleExecutable']
    data = native.read_bytes()
    for marker, recipe in [(b'[self-vm-write] local write', 'build/ntdll-unix/build.sh'),
                           (b'MADEIRA_HIDPAD_OWNER', 'build/wineserver/build.sh')]:
        if marker not in data:
            raise ValueError('linked native runtime lacks ' + marker.decode() + '; rebuild ' + recipe)
    # Both farms must route the game's XInput calls to Steam's hooked DLL.
    # Restoring an old i386 farm can launch games while silently losing input.
    for directory in ['arm64ec-windows', 'i386-windows']:
        data = (bundle / directory / 'sechost.dll').read_bytes()
        marker = 'wine_steam_input_notify'
        if marker.encode() not in data and marker.encode('utf-16le') not in data:
            raise ValueError(directory + '/sechost.dll lacks software XInput device notifications; '
                             'rebuild the Windows runtime')
        for name in ['xinput1_1.dll', 'xinput1_2.dll', 'xinput1_3.dll', 'xinput1_4.dll']:
            data = (bundle / directory / name).read_bytes()
            marker = 'MADEIRA_XINPUT_FORWARD'
            if marker.encode() not in data and marker.encode('utf-16le') not in data:
                raise ValueError(directory + '/' + name +
                                 ' lacks Steam overlay XInput forwarding; rebuild the Windows runtime')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    try:
        check(args.bundle)
    except (OSError, ValueError, KeyError, struct.error) as error:
        parser.exit(1, 'Steam Input runtime check failed: ' + str(error) + '\n')
    print('PASS: Dock/WoW64 dependencies, overlay-write/HID-owner, XInput forwarding and device notifications')
