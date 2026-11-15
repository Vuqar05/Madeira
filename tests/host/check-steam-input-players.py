#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam Input players (milestone 5 item 6).

Player 1 reaches Valve's client as the one virtual HID controller; players
2-4 stay ordinary XInput pads for the game. The process that owns the virtual
controller (MADEIRA_HIDPAD_OWNER, Dock) therefore reads no XInput pad at all,
so Steam Input never takes over another player's pad (with the Xbox identity
the client opens Xbox pads) and never reads a pad twice. This compiles the
production ios_gamepad_hidden_here from build/win32u-unix/driver_ios.c with a
stub for the process image and checks it for the owner, a game, no owner and
case differences; and checks the player-1 rules in GamepadInput.swift.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
driver = (root / 'build/win32u-unix/driver_ios.c').read_text()
gamepad = (root / 'app/Madeira/GamepadInput.swift').read_text()
fails = []
def check(ok, why):
    print(('ok   ' if ok else 'FAIL ') + why)
    if not ok: fails.append(why)

start = driver.index('static int ios_gamepad_hidden_here(void)')
body = driver[start:driver.index('\n}\n', start) + 3]
query = driver[driver.index('ULONG_PTR ios_gamepad_query( UINT index, UINT op, void *buffer )'):]
check('if (op != 3 && ios_gamepad_hidden_here()) return 0;' in query[:600], 'every pad query from the owner process finds no pad')
check('let first = GCController.controllers().first { $0.extendedGamepad != nil }' in gamepad,
      'player 1 is the first paired extended gamepad, as the slots assign it')
check('if !hidKeepsXInput {\n                    winios_gamepad_set_state(Int32(i), nil)' in gamepad,
      'player 1 is not also an XInput pad while it is the virtual controller')
check('static let slot0Reconnect' in gamepad, 'a reconnecting player 1 returns to slot 0 (stable assignment)')

program = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define MAX_PATH 260
#define ERR(...) ((void)0)
static const char *image_path;
static unsigned int GetCurrentProcessId(void) { return 0x20; }
static int winios_drv_process_image(unsigned int pid, char *out, unsigned int size)
{ (void)pid; if (!image_path) return 0; snprintf(out, size, "%s", image_path); return 1; }
''' + body + r'''
static int run(const char *owner, const char *image)
{
    static int hidden; (void)hidden;
    if (owner) setenv("MADEIRA_HIDPAD_OWNER", owner, 1); else unsetenv("MADEIRA_HIDPAD_OWNER");
    image_path = image;
    return ios_gamepad_hidden_here();
}
int main(int argc, char **argv)
{
    int want = atoi(argv[3]);
    int got = run(argv[1][0] ? argv[1] : NULL, argv[2][0] ? argv[2] : NULL);
    if (got != want) { fprintf(stderr, "owner=%s image=%s got %d\n", argv[1], argv[2], got); return 1; }
    /* Decided once per process: a later change does not flip it. */
    if (run(NULL, NULL) != want) return 2;
    return 0;
}
'''
cases = [
    ('dockhost.exe', 'c:\\madeira\\dockhost.exe', 1, 'the owner process (Dock) sees no XInput pads'),
    ('DockHost.exe', 'c:\\madeira\\dockhost.exe', 1, 'the owner name is compared without case'),
    ('dockhost.exe', 'c:\\games\\game.exe', 0, 'a game keeps every XInput pad'),
    ('dockhost.exe', 'c:\\games\\notdockhost.exe', 0, 'only the exact executable name counts'),
    ('', 'c:\\madeira\\dockhost.exe', 0, 'without Steam Input nothing is hidden'),
    ('dockhost.exe', '', 0, 'an unreadable image hides nothing'),
]
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 'hidden.c'; src.write_text(program)
    exe = Path(tmp) / 'hidden'
    r = subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Werror', '-Wno-unused-function', str(src), '-o', str(exe)])
    check(r.returncode == 0, 'production ios_gamepad_hidden_here compiles on the host')
    if r.returncode == 0:
        for owner, image, want, why in cases:
            check(subprocess.run([str(exe), owner, image, str(want)]).returncode == 0, why)
raise SystemExit(f'FAILURES: {len(fails)}' if fails else print('PASS: Steam Input takes player 1 only; players 2-4 stay the game\'s XInput pads'))
