"""Stream OpenSLR 30 (si_lk.tar.gz, CC BY-SA 4.0) and extract a small clean read-speech sample, then abort the transfer.
Excludes utterances whose exact text also occurs in OpenSLR 52 (shared with most fine-tunes' training data).
Usage: python -I prep_slr30_eval.py OUT_DIR LINES_TXT SLR52_TSV N
"""
import sys, tarfile, urllib.request, re, unicodedata, json, os, io, random
import soundfile as sf, numpy as np
out, lines, tsv, N = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def norm(s): return re.sub(r"\s+", " ", unicodedata.normalize("NFC", s).replace("‍", "")).strip()
s52 = {norm(l.split("\t", 2)[2]) for l in open(tsv, encoding="utf8") if l.count("\t") >= 2}
ref = {}
for l in open(lines, encoding="utf8"):
    m = re.match(r'\(\s*(\S+)\s+"(.*)"\s*\)', l)
    t = norm(m.group(2))
    if t not in s52: ref[m.group(1)] = t
print("clean refs", len(ref))
os.makedirs(out, exist_ok=True)
got = {}
req = urllib.request.Request("https://openslr.trmal.net/resources/30/si_lk.tar.gz")
with urllib.request.urlopen(req) as r, tarfile.open(fileobj=r, mode="r|gz") as tf:
    for m in tf:
        if not m.isfile() or not m.name.endswith(".wav"): continue
        uid = os.path.basename(m.name)[:-4]
        if uid not in ref: continue
        got[uid] = tf.extractfile(m).read()
        if len(got) >= N * 3: break          # abort transfer early
random.seed(0)
ids = sorted(got); random.shuffle(ids)
rows = []
for uid in ids[:N]:
    x, sr = sf.read(io.BytesIO(got[uid]), dtype="float32")
    if x.ndim > 1: x = x.mean(1)
    if sr != 16000:
        import subprocess
        # resample via ffmpeg
        p = subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1"], input=got[uid], capture_output=True, check=True)
        x = np.frombuffer(p.stdout, dtype="float32"); sr = 16000
    p = os.path.join(out, uid + ".wav"); sf.write(p, x, sr)
    rows.append({"id": uid + ".wav", "path": p, "text": ref[uid], "dur": len(x) / sr, "mixed": False, "uploader": uid.rsplit("_", 1)[0], "set": "slr30_clean_read"})
with open(os.path.join(out, "manifest.jsonl"), "w") as fo:
    for r in rows: fo.write(json.dumps(r, ensure_ascii=False) + "\n")
print("wrote", len(rows), "speakers", len({r["uploader"] for r in rows}))
