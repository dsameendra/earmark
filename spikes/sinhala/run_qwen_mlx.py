"""Run Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit with Python mlx-audio on manifest.jsonl -> hyps.jsonl.
CAVEAT (from the model card): validated only with mlx-audio-swift >= 01dec7c; Python mlx-audio is untested by the author.
Greedy, no language given, max_tokens = 64 + 30*duration (card recommendation).
Usage: python -I run_qwen_mlx.py MODEL_DIR MANIFEST OUT_JSONL
"""
import sys, json
from mlx_audio.stt.utils import load_model
model = load_model(sys.argv[1])
rows = [json.loads(l) for l in open(sys.argv[2], encoding="utf8")]
with open(sys.argv[3], "w", encoding="utf8") as fo:
    for r in rows:
        cap = int(64 + 30 * r["dur"])
        out = model.generate(r["path"], max_tokens=cap)
        text = getattr(out, "text", str(out)).strip()
        ntok = getattr(out, "generation_tokens", None)
        hit = ntok is not None and ntok >= cap
        fo.write(json.dumps({"id": r["id"], "hyp": text, "hit_cap": bool(hit)}, ensure_ascii=False) + "\n"); fo.flush()
