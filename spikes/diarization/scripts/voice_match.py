"""Cross-session voice-profile check. Map hyp speakers->ref speakers (max overlap) in two meetings of the same
series, then compare centroid cosine distances for same-person vs different-person pairs.
Usage: python -I voice_match.py <ref_dir> <results_dir> <engine> <meetingA> <meetingB>"""
import sys, json
from collections import defaultdict
from pyannote.database.util import load_rttm
import numpy as np
ref_dir, res, eng, ma, mb = sys.argv[1:]
def cos(a, b): a, b = np.array(a), np.array(b); return 1 - a @ b / (np.linalg.norm(a) * np.linalg.norm(b))
def load(m):
    ref = next(iter(load_rttm(f"{ref_dir}/{m}.rttm").values()))
    hyp = next(iter(load_rttm(f"{res}/{eng}-{m}.rttm").values()))
    emb = json.load(open(f"{res}/{eng}-{m}.json"))["embeddings"]
    mp = {}
    for h in hyp.labels():
        ov = defaultdict(float); ht = hyp.label_timeline(h)
        for r in ref.labels(): ov[r] = ref.label_timeline(r).crop(ht).duration() if False else sum(
            (s & t).duration for s in ref.label_timeline(r) for t in ht.crop(s, mode='intersection')) if False else ref.label_timeline(r).co_iter(ht) and sum((a & b).duration for a, b in ref.label_timeline(r).co_iter(ht))
        best = max(ov, key=ov.get); mp[h] = (best, ov[best] / max(ht.duration(), 1e-9))
    return mp, emb
(pa, ea), (pb, eb) = load(ma), load(mb)
same, diff = [], []
print("hyp->ref (purity)  A:", {k: (v[0], round(v[1], 2)) for k, v in pa.items()})
print("hyp->ref (purity)  B:", {k: (v[0], round(v[1], 2)) for k, v in pb.items()})
for ka in ea:
    for kb in eb:
        d = cos(ea[ka], eb[kb]); (same if pa[ka][0] == pb[kb][0] else diff).append((round(float(d), 3), ka, kb, pa[ka][0], pb[kb][0]))
# NOTE: pyannote/AMI ids (e.g. MEO015) are per-meeting-series person ids, stable across ES2004a/b.
print("SAME-person distances:", sorted(same)[:12])
print(f"same: n={len(same)} max={max(x[0] for x in same):.3f} | diff: n={len(diff)} min={min(x[0] for x in diff):.3f} median={np.median([x[0] for x in diff]):.3f}")
