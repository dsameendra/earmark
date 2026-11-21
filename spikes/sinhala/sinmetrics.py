"""Shared normalisation + metrics for Sinhala ASR evaluation (one normaliser for every model)."""
import re, unicodedata, json, sys
import jiwer

ZW = "‍‌"
def norm(s: str, strip_zw: bool = True) -> str:
    s = unicodedata.normalize("NFC", s or "")
    if strip_zw: s = re.sub(f"[{ZW}]", "", s)
    s = s.lower()
    # drop punctuation/symbols (Unicode categories P*, S*), keep letters, marks, digits
    s = "".join(" " if unicodedata.category(c)[0] in "PS" else c for c in s)
    return re.sub(r"\s+", " ", s).strip()

def loop_cut(s: str, min_rep: int = 4) -> str:
    """Cut a degenerate repetition loop where it begins (mimics a loop guard)."""
    m = re.search(r"(.{1,40}?)\1{%d,}" % (min_rep - 1), s)
    return s[: m.start() + len(m.group(1))].strip() if m else s

def cer(ref, hyp):
    r, h = ref.replace(" ", ""), hyp.replace(" ", "")
    return jiwer.cer(r, h) if r else float("nan")

def counts(ref, hyp):
    """Return (edit errors, ref length) for corpus-level aggregation."""
    r, h = ref.replace(" ", ""), hyp.replace(" ", "")
    o = jiwer.process_characters(r, h)
    return o.substitutions + o.deletions + o.insertions, len(r)

def wcounts(ref, hyp):
    o = jiwer.process_words(ref, hyp)
    return o.substitutions + o.deletions + o.insertions, len(ref.split())

def latin_frac(s):
    letters = [c for c in s if c.isalpha()]
    return sum("LATIN" in unicodedata.name(c, "") for c in letters) / len(letters) if letters else 0.0

def score(manifest_jsonl, hyp_jsonl):
    refs = {json.loads(l)["id"]: json.loads(l) for l in open(manifest_jsonl, encoding="utf8")}
    hyps = [json.loads(l) for l in open(hyp_jsonl, encoding="utf8")]
    groups = {}
    for h in hyps:
        r = refs[h["id"]]
        key = (r["set"], "mixed" if r["mixed"] else "sinhala-only")
        for k in (key, (r["set"], "all")):
            groups.setdefault(k, []).append((r, h))
    out = {}
    for k, items in sorted(groups.items()):
        res = {"n": len(items)}
        for label, fn, zw in (("cer", counts, True), ("cer_keepzw", counts, False)):
            for cut in (False, True):
                e = t = 0
                for r, h in items:
                    hyp = loop_cut(h["hyp"]) if cut else h["hyp"]
                    a, b = fn(norm(r["text"], zw), norm(hyp, zw)); e += a; t += b
                res[f"{label}{'_cut' if cut else '_raw'}"] = round(100 * e / t, 2)
        for cut in (False, True):
            e = t = 0
            for r, h in items:
                hyp = loop_cut(h["hyp"]) if cut else h["hyp"]
                a, b = wcounts(norm(r["text"]), norm(hyp)); e += a; t += b
            res[f"wer{'_cut' if cut else '_raw'}"] = round(100 * e / t, 2)
        res["runaway_clips"] = sum(1 for r, h in items if loop_cut(h["hyp"]) != h["hyp"].strip() or h.get("hit_cap"))
        res["ref_latin_frac"] = round(sum(latin_frac(r["text"]) for r, h in items) / len(items), 3)
        res["hyp_latin_frac"] = round(sum(latin_frac(h["hyp"]) for r, h in items) / len(items), 3)
        res["empty_hyp"] = sum(1 for r, h in items if not norm(h["hyp"]))
        out[f"{k[0]} / {k[1]}"] = res
    return out

if __name__ == "__main__":
    print(json.dumps(score(sys.argv[1], sys.argv[2]), ensure_ascii=False, indent=1))
