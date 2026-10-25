"""The launcher offers frame buffering only for the graphics API selected by the packer."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('launcher_settings', ROOT / 'dm/games/settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class LauncherSettingsTests(unittest.TestCase):
    def test_frame_buffering_by_graphics_api(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US']):
            for api, gid in [('nvn', '01007EF00011E000'), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000'), ('', '01007EF00011E000')]:
                with self.subTest(api=api), patch.dict(os.environ, {'GFXAPI': api}):
                    rows = settings.build(gid, tmp, Path(tmp) / 'control.nacp')['settings']
                    found = [s for s in rows if s['env'] == 'DM_PRESENT_SNAP']
                    self.assertEqual(len(found), int(api == 'nvn'))
                    if found:
                        self.assertEqual(found[0]['kind'], 'toggle')
                        self.assertEqual(found[0]['default'], '1')
                        self.assertIn('latency', found[0]['note'])


if __name__ == '__main__':
    unittest.main()
