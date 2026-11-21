"""Run a (fine-tuned) HF Whisper checkpoint on manifest.jsonl -> hyps.jsonl. CPU, greedy, forced Sinhala.
Usage: python -I run_hf_whisper.py MODEL_ID_OR_DIR MANIFEST OUT_JSONL [--revision SHA] [--lang si]
No speed numbers are recorded on purpose (shared machine).
"""
import sys, json, argparse, torch, soundfile as sf
from transformers import WhisperForConditionalGeneration, WhisperProcessor
ap = argparse.ArgumentParser(); ap.add_argument("model"); ap.add_argument("manifest"); ap.add_argument("out")
ap.add_argument("--revision", default=None); ap.add_argument("--lang", default="sinhala")
a = ap.parse_args()
torch.set_num_threads(4)
proc = WhisperProcessor.from_pretrained(a.model, revision=a.revision)
model = WhisperForConditionalGeneration.from_pretrained(a.model, revision=a.revision, torch_dtype=torch.float32).eval()
rows = [json.loads(l) for l in open(a.manifest, encoding="utf8")]
with open(a.out, "w", encoding="utf8") as fo:
    for r in rows:
        x, sr = sf.read(r["path"], dtype="float32"); assert sr == 16000
        feats = proc(x, sampling_rate=16000, return_tensors="pt").input_features
        cap = min(440, int(64 + 30 * r["dur"]))
        with torch.no_grad():
            ids = model.generate(feats, language=a.lang, task="transcribe", max_new_tokens=cap, num_beams=1, do_sample=False)
        hyp = proc.batch_decode(ids, skip_special_tokens=True)[0].strip()
        hit = ids.shape[1] >= cap
        fo.write(json.dumps({"id": r["id"], "hyp": hyp, "hit_cap": bool(hit)}, ensure_ascii=False) + "\n"); fo.flush()
