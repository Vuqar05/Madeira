#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam Input editing uses the native path only (milestone 5 item 8).

With Controller = Steam Input, Game details and the session menu lead to the
native layouts (community and personal layouts, the native editor), never to
Madeira's keyboard-and-mouse binds editor; the Steam Input code does not use
the emulation (ControllerSetup, PadKeyboardMouse); and no migration from the
separate emulation branch is offered (owner waiver, 2026-11-15).
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
library = (app / 'Library.swift').read_text()
fails = []
def check(ok, why):
    print(('ok   ' if ok else 'FAIL ') + why)
    if not ok: fails.append(why)

# Every entry to the binds editor sits inside a keyboard-and-mouse branch.
for m in re.finditer(r'NavigationLink\("Controller binds"\)|Button\("Controller binds"', library):
    before = library[max(0, m.start() - 400):m.start()]
    check('controllerMode == "keys"' in before, f'binds editor at offset {m.start()} is offered only for Keyboard and mouse')
status = library[library.index('private struct SteamInputStatusView: View {'):library.index('/// Game details › Launch arguments:')]
check('SteamInputCommunityView(appID: appID)' in status and 'ControllerBindsPage' not in status,
      'the Steam Input controls open the native layouts, not the binds editor')
community = (app / 'SteamInputCommunityView.swift').read_text()
check('SteamInputPersonalLayoutsSection(' in community, 'personal layouts and the native editor are reachable from there')
code = ''
for path in sorted(app.glob('SteamInput*.swift')) + [app / 'DockSteamInput.swift']:
    text = path.read_text()
    code += re.sub(r'//.*', '', text)
check(not re.search(r'\b(ControllerSetup|PadKeyboardMouse|PadBindings)\b', code), 'no Steam Input code uses the emulation')
check('steam-input-layouts' not in code and 'SteamInputLayouts' not in code, 'no migration from the emulation branch is offered')
raise SystemExit(f'FAILURES: {len(fails)}' if fails else print('PASS: Steam Input editing is routed to the native path only'))
