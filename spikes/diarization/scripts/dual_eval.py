"""Synthetic dual-track live check. mic = IS1009a (all speakers collapsed to 'You'), remote = ES2004a (diarized live).
Optional bleed: mic += g*remote. Reference = ES2004a speakers (prefixed R) + union of IS1009a speech as 'You'.
Usage: python -I dual_eval.py <ref_dir> <results_dir> <hyp_rttm_basename> [crop_seconds]
Reports DER (protocol A) plus 'You' precision/recall on its own."""
import sys
from pyannote.database.util import load_rttm
from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate
ref_dir, res, tag, crop = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else None
remote = next(iter(load_rttm(f"{ref_dir}/ES2004a.rttm").values()))
mic = next(iter(load_rttm(f"{ref_dir}/IS1009a.rttm").values()))
hyp = next(iter(load_rttm(f"{res}/{tag}.rttm").values()))
end = min(remote.get_timeline().extent().end, mic.get_timeline().extent().end) if crop is None else crop
ref = Annotation()
for s, _, l in remote.itertracks(yield_label=True): ref[s] = "R" + l
for s in mic.get_timeline().support(): ref[s] = "You"
uem = Timeline([Segment(0, end)])
met = DiarizationErrorRate(collar=0.0, skip_overlap=False); der = met(ref, hyp, uem=uem); d = met[:]
print(f"{tag}: DER {100*der:.1f}% miss {100*d['missed detection']/d['total']:.1f} fa {100*d['false alarm']/d['total']:.1f} conf {100*d['confusion']/d['total']:.1f}")
you_ref = ref.label_timeline("You").crop(uem); you_hyp = hyp.label_timeline("You").crop(uem) if "You" in hyp.labels() else Timeline()
inter = sum((a & b).duration for a, b in you_ref.co_iter(you_hyp))
print(f"You: precision {inter/max(you_hyp.duration(),1e-9):.2f} recall {inter/max(you_ref.duration(),1e-9):.2f} (ref {you_ref.duration():.0f}s hyp {you_hyp.duration():.0f}s)")
