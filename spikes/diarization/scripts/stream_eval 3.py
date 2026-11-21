"""Evaluate streaming runs. Usage: python -I stream_eval.py <ref_dir> <uem_dir> <results_dir> <kind> <meeting>...
Reports per kind: DER (protocol A strict, B lenient) vs reference; DER vs the OFFLINE FluidAudio hypothesis (agreement,
live-vs-final reconciliation proxy); label stability; latency in AUDIO time (not wall clock); slot usage.
Stability metrics:
 - dominant-slot share: for each reference speaker, the fraction of its (matched) speech carried by its most-used slot
   (1.0 = never changes label; lower = identity splits/flips between slots).
 - tentative revision rate: fraction of tentative frames whose slot set differed from the later finalized slot set.
 - slot count used vs reference speaker count.
"""
import sys, json, statistics as st
from collections import defaultdict
from pathlib import Path
from pyannote.database.util import load_rttm
from pyannote.core import Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate
ref_dir, uem_dir, res, kind, *meetings = sys.argv[1:]
H = 0.1
def uem_of(m):
    _, _, s, e = Path(f"{uem_dir}/{m}.uem").read_text().split()[:4]; return Timeline([Segment(float(s), float(e))])
tot = {"A": defaultdict(float), "B": defaultdict(float)}; totoff = defaultdict(float)
lat_fin, lat_ten, rev_num, rev_den = [], [], 0, 0
for m in meetings:
    ref = next(iter(load_rttm(f"{ref_dir}/{m}.rttm").values()))
    hyp = next(iter(load_rttm(f"{res}/stream/stream-{kind}-{m}.rttm").values()))
    off = next(iter(load_rttm(f"{res}/fluid-{m}.rttm").values()))
    uem = uem_of(m)
    line = [m]
    for name, kw in (("A", dict(collar=0.0, skip_overlap=False)), ("B", dict(collar=0.25, skip_overlap=True))):
        met = DiarizationErrorRate(**kw); der = met(ref, hyp, uem=uem); d = met[:]
        for k in d: tot[name][k] += d[k]
        line.append(f"{name}={100*der:.1f}% (miss {100*d['missed detection']/d['total']:.1f} fa {100*d['false alarm']/d['total']:.1f} conf {100*d['confusion']/d['total']:.1f})")
    met = DiarizationErrorRate(collar=0.0, skip_overlap=False); der_off = met(off, hyp, uem=uem); d = met[:]
    for k in d: totoff[k] += d[k]
    line.append(f"vs-offline {100*der_off:.1f}%")
    # dominant-slot share per reference speaker (slot = hyp label)
    share = {}
    for r in ref.labels():
        rt = ref.label_timeline(r); per = {h: sum((a & b).duration for a, b in rt.co_iter(hyp.label_timeline(h))) for h in hyp.labels()}
        tt = sum(per.values()); share[r] = max(per.values()) / tt if tt else 0
    line.append("dom-slot share " + " ".join(f"{v:.2f}" for v in share.values()))
    line.append(f"ref_spk {len(ref.labels())} slots_used {len(hyp.labels())}")
    print("; ".join(line))
    # latency + tentative revision from the update log
    log = json.load(open(f"{res}/stream/stream-{kind}-{m}.json"))
    n = int(max((u["fed"] for u in log["updates"]), default=0) / H) + 2
    final = defaultdict(set)
    for u in log["updates"]:
        for t in u["finalized"]:
            lat_fin.append(u["fed"] - t["end"])
            for f in range(int(t["start"] / H), min(n, int(t["end"] / H))): final[f].add(t["speaker"])
    seen = set()
    for u in log["updates"]:
        for t in u["tentative"]:
            key = (t["speaker"], round(t["start"], 1))
            if key not in seen: seen.add(key); lat_ten.append(u["fed"] - t["start"])
    # revision: take the LAST tentative view of each frame before finalization is unknowable here; use FIRST view
    first = {}
    for u in log["updates"]:
        for t in u["tentative"]:
            for f in range(int(t["start"] / H), int(t["end"] / H)):
                first.setdefault(f, set()).add(t["speaker"])
    for f, s in first.items():
        rev_den += 1; rev_num += (s != final.get(f, set()))
for name in "AB":
    t = tot[name]; print(f"POOLED {name}: DER {100*(t['missed detection']+t['false alarm']+t['confusion'])/t['total']:.1f}%")
print(f"POOLED vs offline-fluid (strict): {100*(totoff['missed detection']+totoff['false alarm']+totoff['confusion'])/totoff['total']:.1f}%")
q = lambda xs, p: sorted(xs)[int(p * (len(xs) - 1))] if xs else float('nan')
print(f"audio-time lag to FINALIZE a segment (fed - segment end), s: p50 {q(lat_fin,.5):.2f} p90 {q(lat_fin,.9):.2f} max {max(lat_fin, default=float('nan')):.2f}")
print(f"audio-time lag to first TENTATIVE label (fed - segment start), s: p50 {q(lat_ten,.5):.2f} p90 {q(lat_ten,.9):.2f}")
print(f"tentative first-view frames differing from final: {100*rev_num/max(rev_den,1):.1f}% of {rev_den} frames")
