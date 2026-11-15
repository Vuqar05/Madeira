#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Milestone 4 item 4: the personal-layout list, page and editor on a simulator.

Requires Xcode, xcodegen and an iOS Simulator UUID from the device tools:
    python3 tests/host/check-steam-input-editor-ui.py --simulator <UUID>
The probe builds the production editor, store, live-edit coordinator, layout
service (extracted from DockSteamInput.swift as the host checks do) and Dock's C
transaction code. Only the Steam network, logging and the Dock drive are stubbed.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
fixtures = Path(__file__).with_name('steam-input-editor')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator', required=True, help='iOS Simulator UUID')
parser.add_argument('--work-dir', type=Path, help='Keep generated project and results here')
parser.add_argument('--only', help='Run one test, e.g. EditorTests/testModesAndActionSets')
args = parser.parse_args()
work = args.work_dir or Path(tempfile.mkdtemp(prefix='madeira-input-editor-ui-'))
if (work / 'Sources').exists(): shutil.rmtree(work / 'Sources')
(work / 'Sources').mkdir(parents=True)
(work / 'dock').mkdir(exist_ok=True)

service = (app / 'DockSteamInput.swift').read_text()
service = 'import Foundation\nenum DockSteamInputWire' + service.split('enum DockSteamInputWire', 1)[1].split("/// Steam Input's PlayStation setting", 1)[0]
(work / 'Sources/Service.swift').write_text(service)
workshop = (app / 'SteamWorkshopFiles.swift').read_text()
(work / 'Sources/Workshop.swift').write_text(workshop[:workshop.index("/// Valve's record of an app's installed Workshop items:")])
for name in ['SwiftSteam/Library/SteamAppInfo.swift', 'SwiftSteam/Proto/SteamProtoMessages.swift', 'SwiftSteam/Core/SteamError.swift',
             'SteamKeyValues.swift', 'SteamInputVDF.swift', 'SteamInputModel.swift', 'SteamInputReferences.swift', 'SteamInputActions.swift',
             'SteamInputPreview.swift', 'SteamInputTransactions.swift', 'SteamInputDefaults.swift', 'SteamInputCommunity.swift',
             'SteamInputEditor.swift', 'SteamInputPersonalReferences.swift', 'SteamInputPersonalRevisions.swift', 'SteamInputLiveEdit.swift',
             'SteamInputEditorView.swift', 'SteamInputPersonalView.swift']:
    shutil.copyfile(app / name, work / 'Sources' / Path(name).name)
for name in ['steam_input_service.c', 'steam_input_service.h']:
    shutil.copyfile(root / 'madeira-dock/src' / name, work / ('Sources' if name.endswith('.c') else 'dock') / name)
shutil.copyfile(fixtures / 'Probe.swift', work / 'Sources/Probe.swift')
for name in ('project.yml', 'EditorTests.swift', 'Bridge.h'):
    shutil.copyfile(fixtures / name, work / name)
subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.yml')], check=True)
log = work / 'test.log'
command = ['xcodebuild', '-project', str(work / 'EditorProbe.xcodeproj'), '-scheme', 'EditorProbe', '-configuration', 'Debug',
           '-destination', f'id={args.simulator}', '-derivedDataPath', str(work / 'build'), 'test']
if args.only: command.append(f'-only-testing:EditorTests/EditorTests/{args.only}')
with log.open('w') as output:
    result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
print(f"{'PASS' if result.returncode == 0 else 'FAIL'}: Steam Input personal-layout editor on the simulator; log: {log}")
raise SystemExit(result.returncode)
