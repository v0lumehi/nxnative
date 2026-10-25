#!/usr/bin/env python3
# scripts/bench.py: the measured window of the host's per-frame rows (DM_NVN_TSV) and the percentiles taken from it, and the profiles' bench.tsv routes
import importlib.util, os, sys, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('bench', REPO / 'scripts/bench.py'); bench = importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)


class Bench(unittest.TestCase):
    def test_window_and_percentiles(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'frames.tsv'
            rows = ['# kind: nvn-per-frame', 'frame\tname\tvalue']
            for i in range(200):   # 100 frames before the window, 100 in it: 99 of 10 ms and one of 50 ms; the GPU time of the last frame in the window not known yet
                t = 10 + i * 0.01
                rows += [f'{i}\t@t_s\t{t:.3f}', f'{i}\t@frame_ms\t{50.0 if i == 150 else 10.0}', f'{i}\t@presented_ms\t{-1 if i == 160 else 8.333}']
                if i < 199: rows.append(f'{i}\t@gpu_ms\t{7.0 + (i % 10) * 0.1:.1f}')
                rows.append(f'{i}\tnvnQueueSubmitCommands\t3')   # call-count rows are not timing rows
            f.write_text('\n'.join(rows) + '\n')
            ft, shown, gpu, dropped, n = bench.frames(f, 11.0, 12.0)
            self.assertEqual(n, 100); self.assertEqual(len(ft), 100); self.assertEqual(dropped, 1); self.assertEqual(len(shown), 99); self.assertEqual(len(gpu), 99)
            s = bench.summary(ft, shown, gpu, dropped, n, 1.0, 1000 / 120)
            self.assertEqual(s['fps'], 100.0); self.assertEqual(s['frame_p50'], 10.0); self.assertEqual(s['frame_p99'], 10.0); self.assertEqual(s['frame_max'], 50.0)
            self.assertEqual(s['over_budget'], 1)   # only the 50 ms frame is longer than 1.5 × 8.33 ms

    def test_percentile(self):
        xs = list(range(1, 101))
        self.assertEqual(bench.pct(xs, 50), 50); self.assertEqual(bench.pct(xs, 99), 99); self.assertEqual(bench.pct(xs, 100), 100); self.assertIsNone(bench.pct([], 50))

    def test_profile_routes(self):   # every bench.tsv parses: four columns at least, numbers in the window columns
        for t in (REPO / 'dm/games').glob('*/bench.tsv'):
            rs = bench.routes(t.parent.name)
            self.assertTrue(rs, t)
            for name, r in rs.items(): self.assertTrue(r['keys'] and r['secs'] > 0 and r['from'] >= 0, f'{t}: {name}')


if __name__ == '__main__':
    unittest.main()
