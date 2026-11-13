#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise the real status view in session-overlay and Game details contexts.

Requires Xcode, xcodegen and an iOS Simulator UUID from the device tools:
    python3 tests/host/check-steam-input-navigation.py --simulator <UUID>
Only the Steam service and community destination are stubbed. SwiftUI navigation,
periodic refresh, nested navigation, dismissal and reopening run on the simulator.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
fixtures = Path(__file__).with_name("steam-input-navigation")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator", required=True, help="iOS Simulator UUID")
parser.add_argument("--work-dir", type=Path, help="Keep generated project and results here")
args = parser.parse_args()
work = args.work_dir or Path(tempfile.mkdtemp(prefix="madeira-input-navigation-"))
work.mkdir(parents=True, exist_ok=True)
source = (root / "app/Madeira/Library.swift").read_text()
start = source.index("private struct SteamInputStatusView: View {")
end = source.index("/// Game details › Launch arguments:", start)
(work / "App.swift").write_text("import SwiftUI\n" + source[start:end] + (fixtures / "Stubs.swift").read_text())
for name in ("project.yml", "NavigationTests.swift"):
    shutil.copyfile(fixtures / name, work / name)
subprocess.run(["xcodegen", "generate", "--spec", str(work / "project.yml")], check=True)
log = work / "test.log"
with log.open("w") as output:
    result = subprocess.run([
        "xcodebuild", "-project", str(work / "NavigationProbe.xcodeproj"),
        "-scheme", "NavigationProbe", "-destination", f"id={args.simulator}",
        "-derivedDataPath", str(work / "build"), "test",
    ], stdout=output, stderr=subprocess.STDOUT)
print(f"{'PASS' if result.returncode == 0 else 'FAIL'}: Steam Input community navigation; log: {log}")
raise SystemExit(result.returncode)
