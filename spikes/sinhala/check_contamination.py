"""Check how many eval references occur verbatim in SinhaSpeech/sinhala-asr-data (v3, un-normalised text) by split+source.
Reads only the text/source columns over HTTP. Usage: python -I check_contamination.py MANIFEST [MANIFEST...]"""
import sys, json, re, unicodedata, collections
import pyarrow.parquet as pq
from huggingface_hub import HfFileSystem
def n(s): return re.sub(r"\s+", " ", unicodedata.normalize("NFC", s).replace("‍", "")).strip().lower()
fs = HfFileSystem()
idx = collections.defaultdict(set)
for sp in ("train", "validation", "test"):
    with fs.open(f"datasets/SinhaSpeech/sinhala-asr-data/data/stratified_v3/{sp}.parquet", "rb") as fh:
        t = pq.ParquetFile(fh).read(columns=["text", "source_dataset"]).to_pylist()
    for r in t: idx[n(r["text"])].add((sp, r["source_dataset"]))
    print(sp, len(t), flush=True)
for mf in sys.argv[1:]:
    rows = [json.loads(l) for l in open(mf, encoding="utf8")]
    hit = collections.Counter(); 
    for r in rows:
        for s in idx.get(n(r["text"]), []): hit[s] += 1
    print(mf, "n", len(rows), "matched any:", sum(1 for r in rows if n(r["text"]) in idx), dict(hit))
