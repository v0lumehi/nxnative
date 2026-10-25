#!/usr/bin/env python3
"""End-to-end frame timeline and frame budget of a run (iPhone or Mac).

Reads the run's per-frame rows (DM_NVN_TSV, best with DM_NVN_TSV_CALLS=0), its log (DM_CTL marks, [gpuprof] lines of DM_NVN_GPUPROF=every:n, the periodic
"threads up to frame" lines) and, when given, an Instruments recording of the same run (xcrun xctrace record --template 'Metal System Trace' --all-processes):
the GPU's vertex / fragment / compute channel intervals, its performance state, and the time profile's CPU samples by thread.

  frame_timeline.py <run folder> [--from-mark NAME] [--to-mark NAME] [--frames A-B] [--trace FILE.trace] [--json OUT]

The run folder holds frames.tsv and log.txt (auto_run.sh pulls both there). Times in the rows are ms since process start on one clock (mach_absolute_time,
which GPUStartTime and presentedTime share). Per frame f, on the thread that submits and presents (the game's render thread):

  previous present ── acquire (pacing wait: @wait_ms + @pq_wait_ms) ── @ft_acq ── game ── @ft_sub0 ── submits (@sub_wall_ms) ── @ft_sub1 ── game ── present (@call_ms)
  encode thread: @ft_enc_ms of work; main command buffers committed at @ft_commit0 .. @ft_commit1; GPU from @gpu_beg to @gpu_end, busy @gpu_ms;
  display command buffer committed at @ft_pcommit; on screen at @pres_at.
"""
import argparse, collections, json, os, re, statistics, subprocess, sys
import xml.etree.ElementTree as ET


def pct(v, p):
    v = sorted(x for x in v if x is not None)
    if not v: return None
    return v[min(len(v) - 1, int(len(v) * p / 100))]


def read_tsv(path):
    rows = collections.defaultdict(dict)
    with open(path, errors='replace') as f:
        for line in f:
            p = line.rstrip('\n').split('\t')
            if len(p) != 3 or not p[1].startswith('@') or not p[0].isdigit(): continue
            try: rows[int(p[0])][p[1][1:]] = float(p[2])
            except ValueError: pass
    return rows


def read_log(path):
    marks, gp, gpf, threads = [], collections.defaultdict(list), {}, []
    rx_mark = re.compile(r'DM_CTL: mark (.*) \(frame (\d+)\)')
    rx_gp = re.compile(r'\[gpuprof\] F(\d+)\s+(\d+)\s+([\d.]+) us (render pass|compute / copy)(.*?) start ([+-][\d.]+) seg (\d+)(.*)')
    rx_gpf = re.compile(r'\[gpuprof\] frame (\d+): render ([\d.]+) ms, compute / copy ([\d.]+) ms .* first start to last end ([\d.]+) ms; clock proxy: tiny-pass median ([\d.]+) us over \d+, hold (\d+), thermal (-?\d+)')
    rx_thr = re.compile(r'threads up to frame (\d+): CPU by guest priority .*?top: (.*)')
    with open(path, errors='replace') as f:
        for line in f:
            m = rx_mark.search(line)
            if m: marks.append((m.group(1).strip(), int(m.group(2)))); continue
            if '[gpuprof]' in line:
                m = rx_gp.search(line)
                if m:
                    F, i, us, kind, desc, start, seg, rest = m.groups()
                    e = {'us': float(us), 'kind': 'render' if kind == 'render pass' else 'compute', 'start': float(start), 'desc': desc.strip()}
                    md = re.search(r'(\d+)x(\d+) colors (\d+) depth (\d+) loads (\d+) draws (\d+)', desc)
                    if md: e.update(zip(('w', 'h', 'colors', 'depth', 'loads', 'draws'), map(int, md.groups())))
                    gp[int(F)].append(e); continue
                m = rx_gpf.search(line)
                if m: gpf[int(m.group(1))] = dict(zip(('render', 'compute', 'span', 'tiny_us', 'hold', 'thermal'), map(float, m.groups()[1:])))
                continue
            m = rx_thr.search(line)
            if m:
                tops = re.findall(r"(0x[0-9a-f]+) '([^']*)' priority (\d+) (\d+) ms/s", m.group(2))
                threads.append((int(m.group(1)), [(h, n, int(ms)) for h, n, p, ms in tops]))
    return marks, gp, gpf, threads


def frame_range(rows, marks, a):
    lo, hi = min(rows), max(rows)
    if a.frames:
        x, y = a.frames.split('-'); return int(x), int(y)
    mk = {}
    for n, fr in marks: mk.setdefault(n, fr)
    if a.from_mark:
        if a.from_mark not in mk: sys.exit(f'no mark {a.from_mark!r} in the log (marks: {", ".join(n for n, _ in marks) or "none"})')
        lo = mk[a.from_mark]
        later = [fr for n, fr in marks if fr > lo]
        hi = mk[a.to_mark] if a.to_mark and a.to_mark in mk else (later[0] if later else hi)
    return lo, hi - 9   # the last 8 frames' GPU and display rows come 8 presents late


def timeline(rows, lo, hi):
    out = []
    for f in range(lo, hi + 1):
        r, p = rows.get(f), rows.get(f - 1)
        if not r or not p or 'call_ms' not in r or 'ft_acq_ms' not in r: continue
        d = {'f': f, 'period': r.get('frame_ms')}
        d['pace_wait'] = r.get('wait_ms', 0) + r.get('pq_wait_ms', 0)
        d['submit_wall'] = r.get('sub_wall_ms'); d['submit_cpu'] = r.get('sub_cpu_ms'); d['nsub'] = r.get('ft_nsub')
        d['sync_wait'] = r.get('ft_sync_ms'); d['encode'] = r.get('ft_enc_ms')
        d['game_rt'] = max(0.0, d['period'] - d['pace_wait'] - (d['submit_wall'] or 0)) if d['period'] else None
        acq = r['ft_acq_ms']
        if 'ft_sub0_ms' in r:
            d['acq_to_sub0'] = r['ft_sub0_ms'] - acq; d['sub1_to_present'] = r['call_ms'] - r['ft_sub1_ms']
        if 'gpu_beg_ms' in r:
            d['gpu_busy'] = r.get('gpu_ms'); d['gpu_span'] = r['gpu_end_ms'] - r['gpu_beg_ms']
            if 'ft_commit0_ms' in r:
                d['commit_to_gpu'] = r['gpu_beg_ms'] - r['ft_commit0_ms']; d['gpu_end_after_commit'] = r['gpu_end_ms'] - r['ft_commit1_ms']
            if 'ft_pcommit_ms' in r: d['gpu_end_to_pcommit'] = r['ft_pcommit_ms'] - r['gpu_end_ms']
            n = rows.get(f + 1)
            if n and 'gpu_beg_ms' in n: d['gpu_gap_next'] = n['gpu_beg_ms'] - r['gpu_end_ms']
        if 'pres_at_ms' in r:
            if 'ft_pcommit_ms' in r: d['pcommit_to_screen'] = r['pres_at_ms'] - r['ft_pcommit_ms']
            d['start_to_screen'] = r['pres_at_ms'] - acq; d['present_to_screen'] = r['pres_at_ms'] - r['call_ms']
        d['on_screen'] = r.get('presented_ms'); d['draws'] = r.get('draws'); d['passes'] = r.get('passes')
        out.append(d)
    return out


# ---------- Instruments recording ----------
def xexport(trace, schema):
    cache = f'{trace.rstrip("/")}.{schema}.xml'   # beside the recording: a file written into the bundle while xctrace reads it made the export come back empty
    if not os.path.exists(cache) or not os.path.getsize(cache):
        with open(cache + '.tmp', 'wb') as o:
            r = subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath', f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], stdout=o, stderr=subprocess.PIPE, check=False)
        if r.returncode or not os.path.getsize(cache + '.tmp'): print(f'[RED] xctrace export {schema}: {r.stderr.decode(errors="replace").strip()[:300]}', file=sys.stderr)
        os.replace(cache + '.tmp', cache)
    return cache


def xrows(path):
    """Rows of an xctrace export as lists of resolved elements (id / ref resolved)."""
    ids = {}
    def res(e):
        r = e.get('ref')
        return ids.get(r, e) if r else e
    for ev, el in ET.iterparse(path, events=('end',)):
        if el.get('id'): ids[el.get('id')] = el
        if el.tag == 'row':
            yield [res(c) for c in el]


def union(iv):
    tot = 0; cs = ce = None
    for s, e in sorted(iv):
        if cs is None: cs, ce = s, e
        elif s <= ce: ce = max(ce, e)
        else: tot += ce - cs; cs, ce = s, e
    return tot + (ce - cs if cs is not None else 0)


def trace_gpu(trace, proc='DmIOS'):
    """The game's GPU channel intervals over the whole recording: busy time per channel (union of intervals), vertex / fragment overlap, idle, and the idle gaps."""
    ch = collections.defaultdict(list)
    for c in xrows(xexport(trace, 'metal-gpu-intervals')):
        p = next((x.get('fmt', '') for x in c if x.tag == 'process'), '')
        if p and proc not in p: continue
        try: start, dur, name = int(c[0].text), int(c[1].text), c[2].get('fmt', c[2].text or '')
        except (AttributeError, ValueError, IndexError, TypeError): continue
        ch[name].append((start, start + dur))
    allv = [iv for v in ch.values() for iv in v]
    if not allv: return None, collections.Counter()
    t0, t1 = min(s for s, e in allv), max(e for s, e in allv)
    V, F, C = ch.get('Vertex', []), ch.get('Fragment', []), ch.get('Compute', [])
    uv, uf, uc, ua = union(V), union(F), union(C), union(allv)
    gaps, ce = [], None
    for s, e in sorted(allv):
        if ce is not None and s > ce: gaps.append(s - ce)
        ce = e if ce is None else max(ce, e)
    res = {'window_s': (t1 - t0) / 1e9, 'vertex': uv, 'fragment': uf, 'compute': uc, 'busy': ua, 'vf_overlap': uv + uf - union(V + F),
           'vertex_only': union(V + F) - uf, 'idle': (t1 - t0) - ua, 'gaps_over_1ms': sum(g for g in gaps if g > 1e6), 'n_gaps_over_1ms': sum(1 for g in gaps if g > 1e6)}
    states = collections.Counter()
    for c in xrows(xexport(trace, 'gpu-performance-state-intervals')):
        try: states[(c[2].get('fmt'), c[4].get('fmt'))] += int(c[1].text)
        except (AttributeError, ValueError, IndexError, TypeError): pass
    return res, states


def trace_threads(trace, proc='DmIOS'):
    cnt, tot, t0, t1 = collections.Counter(), 0, None, None
    for c in xrows(xexport(trace, 'time-profile')):
        th = next((x for x in c if x.tag == 'thread'), None); w = next((x for x in c if x.tag == 'weight'), None); t = c[0]
        if th is None: continue
        name = th.get('fmt', '')
        try: tm = int(t.text); wt = int(w.text) if w is not None else 1000000
        except (TypeError, ValueError): continue
        t0 = tm if t0 is None else min(t0, tm); t1 = tm if t1 is None else max(t1, tm)
        if proc not in name: continue
        cnt[re.sub(r' \(0x[0-9a-f]+\)| \(DmIOS.*', '', name).strip() or name] += wt; tot += wt
    secs = (t1 - t0) / 1e9 if t0 is not None and t1 > t0 else 0
    return cnt, tot, secs


def stats(v):
    v = [x for x in v if x is not None]
    if not v: return None
    return {'mean': statistics.fmean(v), 'p50': pct(v, 50), 'p90': pct(v, 90), 'p99': pct(v, 99), 'n': len(v)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('run'); ap.add_argument('--from-mark'); ap.add_argument('--to-mark'); ap.add_argument('--frames'); ap.add_argument('--trace'); ap.add_argument('--json')
    a = ap.parse_args()
    rows = read_tsv(os.path.join(a.run, 'frames.tsv'))
    if not rows: sys.exit('no per-frame rows (frames.tsv: DM_NVN_TSV)')
    marks, gp, gpf, threads = read_log(os.path.join(a.run, 'log.txt'))
    lo, hi = frame_range(rows, marks, a)
    tl = timeline(rows, lo, hi)
    if not tl: sys.exit(f'no complete frames in {lo}-{hi}')
    out = {'frames': [lo, hi], 'n': len(tl), 'timeline': {}}
    keys = [('period', 'frame interval (present to present)'), ('pace_wait', 'render thread: acquire / pacing wait'),
            ('game_rt', 'render thread: game work (period − pacing − submits)'), ('acq_to_sub0', '  of it: acquire → first submit'), ('sub1_to_present', '  of it: last submit → present'),
            ('submit_wall', 'render thread: host submits (translation + replay), wall'), ('submit_cpu', '  of it: CPU on that thread'), ('nsub', '  submits per frame'),
            ('sync_wait', 'game threads waiting in nvnSyncWait (GPU)'), ('encode', 'encode thread work (Metal encoding)'),
            ('commit_to_gpu', 'first commit → GPU start'), ('gpu_busy', 'GPU busy (command buffer durations)'), ('gpu_span', 'GPU first start → last end'),
            ('gpu_end_after_commit', 'last commit → GPU end'), ('gpu_gap_next', 'GPU end → next frame GPU start'),
            ('gpu_end_to_pcommit', 'GPU end → display command buffer commit'), ('pcommit_to_screen', 'display commit → on screen'),
            ('present_to_screen', 'present call → on screen'), ('start_to_screen', 'frame start (acquire) → on screen'), ('on_screen', 'on-screen interval'),
            ('draws', 'draws'), ('passes', 'render passes')]
    print(f'frames {lo}-{hi}: {len(tl)} complete' + (f'; marks: {", ".join(f"{n}@{fr}" for n, fr in marks)}' if marks else ''))
    print(f'{"":56s} {"mean":>7s} {"p50":>7s} {"p90":>7s} {"p99":>7s}')
    for k, label in keys:
        s = stats([d.get(k) for d in tl])
        if not s: continue
        out['timeline'][k] = s
        print(f'{label:56s} {s["mean"]:7.2f} {s["p50"]:7.2f} {s["p90"]:7.2f} {s["p99"]:7.2f}')
    # Per-pass GPU (DM_NVN_GPUPROF) in the window
    gpw = {F: es for F, es in gp.items() if lo <= F <= hi}
    if gpw:
        groups = collections.defaultdict(list)
        for F, es in gpw.items():
            agg = collections.Counter()
            for e in es:
                if e['kind'] == 'render':
                    key = f'render {e["w"]}x{e["h"]} c{e["colors"]} d{e["depth"]}' + (' draws<=2' if e['draws'] <= 2 else '')
                else: key = 'compute / copy'
                agg[key] += e['us']
            for k, v in agg.items(): groups[k].append(v / 1e3)
        nF = len(gpw)
        print(f'\nGPU per pass group (DM_NVN_GPUPROF, {nF} profiled frames; ms per frame, sum of encoder times):')
        tot = 0
        for k, v in sorted(groups.items(), key=lambda kv: -sum(kv[1])):
            m = sum(v) / nF; tot += m
            if m >= 0.1: print(f'  {k:40s} {m:6.2f}')
        print(f'  {"all":40s} {tot:6.2f}')
        cl = [gpf[F] for F in gpw if F in gpf]
        if cl: print('  clock proxy (tiny-pass median): ' + ', '.join(f'{c["tiny_us"]:.1f} us (hold {int(c["hold"])}, thermal {int(c["thermal"])})' for c in cl[:12]))
        out['gpu_groups'] = {k: sum(v) / nF for k, v in groups.items()}
    thr = [t for t in threads if lo <= t[0] <= hi + 300]
    if thr:
        print('\nbusiest guest threads ("threads up to frame" lines, ms of CPU per second):')
        for fr, tops in thr[:6]: print(f'  up to frame {fr}: ' + ', '.join(f'{n} {ms}' for h, n, ms in tops))
    if a.trace:
        per, states = trace_gpu(a.trace)
        if per:
            fps = 1000 / statistics.fmean([d['period'] for d in tl if d['period']]); nf = per['window_s'] * fps
            print(f'\nInstruments GPU, the game\'s intervals ({per["window_s"]:.1f} s, ms per frame at {fps:.1f} fps; busy = union of the channel\'s intervals):')
            for k in ('busy', 'vertex', 'fragment', 'compute', 'vf_overlap', 'vertex_only', 'idle', 'gaps_over_1ms'):
                print(f'  {k:14s} {per[k] / 1e6 / nf:7.2f}')
            print(f'  idle gaps over 1 ms: {per["n_gaps_over_1ms"] / nf:.2f} per frame')
            out['trace_gpu'] = {k: (v / 1e6 / nf if k not in ('window_s', 'n_gaps_over_1ms') else v) for k, v in per.items()}
        if states:
            tot = sum(states.values())
            print('  GPU performance state: ' + ', '.join(f'{s} ({"induced" if ind == "Yes" else "not induced"}) {100 * v / tot:.0f}%' for (s, ind), v in states.most_common()))
            out['trace_states'] = {f'{s}/{ind}': v / tot for (s, ind), v in states.items()}
        cnt, tot, secs = trace_threads(a.trace)
        if tot and secs:
            fps = 1000 / statistics.fmean([d['period'] for d in tl if d['period']])
            print(f'\nInstruments CPU by thread ({secs:.1f} s; ms per frame at {fps:.1f} fps):')
            for n, w in cnt.most_common(14): print(f'  {n[:60]:60s} {w / 1e6 / secs / fps:6.2f}')
            out['trace_threads'] = {n: w / 1e6 / secs / fps for n, w in cnt.most_common(40)}
    if a.json:
        with open(a.json, 'w') as f: json.dump(out, f, indent=1)


if __name__ == '__main__':
    main()
