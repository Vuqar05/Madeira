#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam Input lifecycle without stuck input (milestone 5 item 5).

Runs the production SteamInputHeldRelease through layout changes, rapid
changes, held buttons and triggers, and a session end; and checks that the pad
sampler uses it for the virtual controller, that the app going inactive or a
pad leaving publishes the controller at rest, and that a session end stops
feedback and forgets the last output report.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
gamepad = (app / 'GamepadInput.swift').read_text()
library = (app / 'Library.swift').read_text()
fails = []
def check(ok, why):
    print(('ok   ' if ok else 'FAIL ') + why)
    if not ok: fails.append(why)

check('let passed = steamInputHeld.filter(buttons: state.buttons, left: state.left_trigger, right: state.right_trigger)' in gamepad,
      'the virtual controller is published through SteamInputHeldRelease')
check('steamInputLatchedButtons' not in gamepad, 'no second copy of the latch')
check('if hid { winios_hidpad_set_state(nil) }' in gamepad, 'no pad and no on-screen controls: the virtual controller reads disconnected/at rest')
check('// Keep the connected identity, but release all controls while the\n            // app is inactive.' in gamepad, 'an inactive app releases every control')
check('madeira_pad_output_set_active(value ? 1 : 0)' in gamepad, 'background stops motors and trigger effects')
check('winios_gamepad_set_vibration(Int32(i), 0, 0)' in gamepad, 'a pad that leaves stops its motors')
check('GamepadInput.shared.endPadSession()' in library, 'the library session end stops feedback')
end = gamepad[gamepad.index('@MainActor func endPadSession()'):]
end = end[:end.index('\n    }\n')]
check('madeira_pad_output_configure(0, 0)' in end and 'winios_hidpad_set_output(&none)' in end and 'steamInputHeld.reset()' in end,
      'session end: motors off, last output report forgotten, held input forgotten')

cases = r'''
func require(_ ok: Bool, _ why: String) { if !ok { fatalError("FAIL: " + why) } }
var g = SteamInputHeldRelease()
let A: UInt16 = 0x1000, B: UInt16 = 0x2000
// Ordinary play passes everything.
var r = g.filter(buttons: A, left: 200, right: 0)
require(r.buttons == A && r.left == 200 && !r.atRest, "ordinary input")
// A layout change starts while A and the left trigger are held: the controller reads at rest.
g.setQuiesced(true)
r = g.filter(buttons: A | B, left: 200, right: 0)
require(r.atRest && r.buttons == 0 && r.left == 0, "at rest during the change")
// The change ends with A and the trigger still held: both stay released; B was let go and comes back as new.
g.setQuiesced(false)
r = g.filter(buttons: A, left: 200, right: 0)
require(r.buttons == 0 && r.left == 0 && !r.atRest, "held input stays released after the change")
r = g.filter(buttons: A | B, left: 200, right: 210)
require(r.buttons == B && r.left == 0 && r.right == 210, "new presses pass at once")
// Letting go clears the latch; the next press passes.
r = g.filter(buttons: 0, left: 10, right: 0)
require(r.buttons == 0 && r.left == 10, "a trigger below the threshold is not a press")
r = g.filter(buttons: A, left: 200, right: 0)
require(r.buttons == A && r.left == 200, "after release, input passes again")
// Rapid changes: each one re-latches what is held; nothing leaks between them.
for _ in 0..<10 {
    g.setQuiesced(true); _ = g.filter(buttons: A, left: 0, right: 255)
    g.setQuiesced(false); r = g.filter(buttons: A, left: 0, right: 255)
    require(r.buttons == 0 && r.right == 0, "rapid change keeps held input released")
}
// The session ends while a change is in flight: the next session starts clean.
g.setQuiesced(true); _ = g.filter(buttons: A, left: 255, right: 255)
g.reset()
r = g.filter(buttons: A, left: 255, right: 0)
require(r.buttons == A && r.left == 255 && !r.atRest && !g.quiesced, "reset forgets the session")
print("ok   held buttons and triggers released across layout changes, rapid changes and session end")
'''
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(cases)
    r = subprocess.run([os.environ.get('SWIFTC') or shutil.which('swiftc'), '-module-cache-path', str(tmp / 'm'),
                        str(app / 'SteamInputController.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'c')])
    check(r.returncode == 0 and subprocess.run([str(tmp / 'c')]).returncode == 0, 'SteamInputHeldRelease state machine')
raise SystemExit(f'FAILURES: {len(fails)}' if fails else print('PASS: Steam Input lifecycle releases held input and feedback'))
