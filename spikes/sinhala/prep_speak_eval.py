"""Build a small held-out eval set from SPEAK-ASR/youtube-sinhala-asr (INTERNAL EVAL ONLY, no licence; never redistribute).
Uses the 5 channels held out of Qwen3-ASR-Sinhala training (Nerdstorm card) so that model's numbers are channel-clean.
Usage: python -I prep_speak_eval.py OUT_DIR N_PER_CELL [--list]
Reads only needed parquet columns/row groups over HTTP (no full download).
"""
import sys, json, random, io, os
import pyarrow.parquet as pq
from huggingface_hub import HfFileSystem
import soundfile as sf
import numpy as np

REPO = "datasets/SPEAK-ASR/youtube-sinhala-asr"
FILES = ["data/train-00000-of-00002.parquet", "data/train-00001-of-00002.parquet",
         "data/validation-00000-of-00001.parquet", "data/test-00000-of-00001.parquet"]
TARGET_KEYS = ["carnage", "newsfirst", "arogya", "anoma", "hera"]  # lowercase substring match on uploader

out_dir, n_cell = sys.argv[1], int(sys.argv[2])
fs = HfFileSystem()
meta = []
for f in FILES:
    with fs.open(f"{REPO}/{f}", "rb") as fh:
        pf = pq.ParquetFile(fh)
        t = pf.read(columns=["text", "duration", "video_id", "uploader", "is_code_mixed", "has_noise"]).to_pylist()
    for i, r in enumerate(t):
        r["file"], r["row"] = f, i
        meta.append(r)
ups = {}
for r in meta:
    ups[r["uploader"]] = ups.get(r["uploader"], 0) + 1
if "--list" in sys.argv:
    for u, c in sorted(ups.items(), key=lambda x: -x[1]): print(c, u)
    sys.exit(0)
cand = [r for r in meta if any(k in (r["uploader"] or "").lower() for k in TARGET_KEYS) and 2.0 <= r["duration"] <= 20.0]
print("candidates", len(cand), "uploaders", sorted({r["uploader"] for r in cand}))
random.seed(0)
pick = []
for mixed in (True, False):
    pool = [r for r in cand if bool(r["is_code_mixed"]) == mixed]
    random.shuffle(pool)
    pick += pool[:n_cell]
os.makedirs(out_dir, exist_ok=True)
byfile = {}
for r in pick: byfile.setdefault(r["file"], []).append(r)
rows = []
for f, rs in byfile.items():
    with fs.open(f"{REPO}/{f}", "rb") as fh:
        pf = pq.ParquetFile(fh)
        # map row -> row group
        starts, s = [], 0
        for g in range(pf.num_row_groups):
            starts.append(s); s += pf.metadata.row_group(g).num_rows
        need = {}
        for r in rs:
            g = max(i for i, st in enumerate(starts) if st <= r["row"]); need.setdefault(g, []).append(r)
        for g, rr in need.items():
            tb = pf.read_row_group(g, columns=["audio"]).column("audio").to_pylist()
            for r in rr:
                a = tb[r["row"] - starts[g]]
                x, sr = sf.read(io.BytesIO(a["bytes"]), dtype="float32")
                if x.ndim > 1: x = x.mean(1)
                assert sr == 16000, sr
                p = os.path.join(out_dir, f"speak_{len(rows):03d}.wav")
                sf.write(p, x, sr)
                rows.append({"id": os.path.basename(p), "path": p, "text": r["text"], "dur": r["duration"],
                             "mixed": bool(r["is_code_mixed"]), "uploader": r["uploader"], "set": "speak_heldout_channels"})
with open(os.path.join(out_dir, "manifest.jsonl"), "w") as fo:
    for r in rows: fo.write(json.dumps(r, ensure_ascii=False) + "\n")
print("wrote", len(rows))
