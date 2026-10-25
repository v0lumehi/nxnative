"""The launcher stores only choices that differ from the game's default, and Reset to tested defaults clears the Advanced page's (launcher_storage_check.swift).

Runs in a booted iOS Simulator (xcrun simctl boot <device>); skipped without one. Launcher.swift is compiled with launcher_storage_check.swift, its private types made internal."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/games'))
import settings


def booted_simulator():
    if not shutil.which('xcrun'): return None
    r = subprocess.run(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j'], capture_output=True, text=True)
    if r.returncode: return None
    devices = [d for ds in json.loads(r.stdout).get('devices', {}).values() for d in ds if d.get('state') == 'Booted']
    return devices[0]['udid'] if devices else None


@unittest.skipUnless(booted_simulator(), 'needs a booted iOS Simulator')
class LauncherStorageTests(unittest.TestCase):
    def test_only_changed_choices_are_stored(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'patched').mkdir()
            (tmp / 'patched/main.fixups.tsv').write_text('# RENDER_SCALE\t1\n')   # the render-scale row, a range
            with patch.dict(os.environ, {'GFXAPI': 'nvn'}), patch.object(settings.nacp, 'languages', return_value=['en-US', 'ja']):
                (tmp / 'launcher.json').write_text(json.dumps(settings.build('01007EF00011E000', tmp / 'patched', tmp / 'control.nacp')))
            src = (REPO / 'dm/ios/Sources/Launcher.swift').read_text(encoding='utf-8')
            (tmp / 'Launcher.swift').write_text(re.sub(r'^(\s*)private ', r'\1', src, flags=re.M), encoding='utf-8')
            exe = tmp / 'launcher_storage_check'
            subprocess.run(['xcrun', '-sdk', 'iphonesimulator', 'swiftc', '-target', 'arm64-apple-ios26.0-simulator', '-swift-version', '5', '-parse-as-library',
                            '-o', str(exe), str(tmp / 'Launcher.swift'), str(Path(__file__).with_name('launcher_storage_check.swift'))], check=True, capture_output=True)
            r = subprocess.run(['xcrun', 'simctl', 'spawn', booted_simulator(), str(exe), str(tmp / 'launcher.json')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('launcher storage: 0 failed', r.stdout)


if __name__ == '__main__':
    unittest.main()
