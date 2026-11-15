#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam Input does not depend on keyboard-and-mouse mode (milestone 5 item 9).

Runs GamepadInput.allowedMode, extracted from the production source, for every
combination of the three switches, and checks that every Steam Input decision
in the launch path and the Controller pickers reads Steam Input's own
availability, not GamepadInput.keyboardMouseAvailable.
"""
from pathlib import Path
import itertools, os, re, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
gamepad = (app / 'GamepadInput.swift').read_text()
content = (app / 'ContentView.swift').read_text()
library = (app / 'Library.swift').read_text()
fails = []
def check(ok, why):
    print(('ok   ' if ok else 'FAIL ') + why)
    if not ok: fails.append(why)

check('keyboardMouseAvailable && profile?.usesSteamInput' not in content, 'launch path: Steam Input is not gated by keyboard-and-mouse mode')
check(content.count('GamepadInput.steamInputAvailable && profile?.usesSteamInput == true') == 3,
      'pad session, runtime files and client settings read Steam Input availability')
check('if GamepadInput.steamInputAvailable, usesSteamInput { setenv("MADEIRA_DOCK_STEAM_INPUT", "1", 1) }' in library,
      'Dock is asked for Steam Input by its own availability')
check('controllerMode = GamepadInput.allowedMode(entry.controllerMode)' in library, 'a saved Steam Input choice survives MADEIRA_PAD_KBM=0')
check(library.count('if GamepadInput.controllerModeAvailable {\n') >= 2, 'Game details and the session menu offer the Controller choice without keyboard-and-mouse mode')
check('if GamepadInput.keyboardMouseAvailable || mode == "keys" { Text("Keyboard and mouse").tag("keys") }' in library,
      'only the keyboard-and-mouse entry depends on MADEIRA_PAD_KBM')

body = gamepad[gamepad.index('    static func allowedMode('):]
body = body[:body.index('\n    }\n') + 7]
program = '''
enum G {
    nonisolated(unsafe) static var controllerModeAvailable = true
    nonisolated(unsafe) static var keyboardMouseAvailable = true
    nonisolated(unsafe) static var steamInputAvailable = true
''' + body + '''
}
for (xinput, kbm, steam) in [(true, true, true), (true, false, true), (true, true, false), (false, true, true), (true, false, false)] {
    G.controllerModeAvailable = xinput; G.keyboardMouseAvailable = xinput && kbm; G.steamInputAvailable = xinput && steam
    for mode in [nil, "dinput", "keys", "steam"] as [String?] {
        let got = G.allowedMode(mode)
        let want: String? = !xinput || mode == nil ? nil : mode == "keys" && !kbm ? nil : mode == "steam" && !steam ? nil : mode
        precondition(got == want, "\\(xinput) \\(kbm) \\(steam) \\(String(describing: mode)) -> \\(String(describing: got))")
    }
}
print("ok   allowedMode keeps Steam Input with keyboard-and-mouse mode off, and drops each mode only with its own switch")
'''
with tempfile.TemporaryDirectory() as tmp:
    (Path(tmp) / 'main.swift').write_text(program)
    r = subprocess.run([os.environ.get('SWIFTC') or shutil.which('swiftc'), '-module-cache-path', str(Path(tmp) / 'm'),
                        str(Path(tmp) / 'main.swift'), '-o', str(Path(tmp) / 'c')])
    check(r.returncode == 0 and subprocess.run([str(Path(tmp) / 'c')]).returncode == 0, 'allowedMode compiles and behaves')
raise SystemExit(f'FAILURES: {len(fails)}' if fails else print('PASS: Steam Input availability is independent of keyboard-and-mouse mode'))
