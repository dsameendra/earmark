"""Score hypothesis RTTMs with pyannote.metrics (independent scorer, same refs/UEM for all engines).
Usage: python -I score_der.py <ref_dir> <uem_dir> <hyp_dir> <engine> <meeting>...
Protocol A: collar 0.0, overlap scored (strict).  Protocol B: collar 0.25, overlap skipped (lenient, the AMI-literature style).
"""
import sys
from pathlib import Path
from pyannote.database.util import load_rttm
from pyannote.core import Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate

ref_dir, uem_dir, hyp_dir, engine, *meetings = sys.argv[1:]
protos = {"A(collar0,overlap scored)": dict(collar=0.0, skip_overlap=False),
          "B(collar0.25,overlap skipped)": dict(collar=0.25, skip_overlap=True)}
for name, kw in protos.items():
    print(f"== {engine} protocol {name}")
    tot = {}
    for m in meetings:
        ref = next(iter(load_rttm(f"{ref_dir}/{m}.rttm").values()))
        hyp = next(iter(load_rttm(f"{hyp_dir}/{engine}-{m}.rttm").values()))
        _, _, s, e = Path(f"{uem_dir}/{m}.uem").read_text().split()[:4]
        uem = Timeline([Segment(float(s), float(e))])
        met = DiarizationErrorRate(**kw)
        der = met(ref, hyp, uem=uem)
        d = met[:]
        print(f"{m}: DER {100*der:.1f}%  miss {100*d['missed detection']/d['total']:.1f} fa {100*d['false alarm']/d['total']:.1f} conf {100*d['confusion']/d['total']:.1f}  ref_spk {len(ref.labels())} hyp_spk {len(hyp.labels())}")
        for k in d: tot[k] = tot.get(k, 0) + d[k]
    print(f"POOLED: DER {100*(tot['missed detection']+tot['false alarm']+tot['confusion'])/tot['total']:.1f}%")
