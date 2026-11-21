"""Score all result files -> results_summary.json (numbers only; no transcripts). Usage: python -I summarize.py EVAL_DIR"""
import sys, json, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sinmetrics as m
E = sys.argv[1]; out = {}
for model in ("qwen", "run12", "turbo"):
    for s, mf in (("slr30", "slr30_wav"), ("speak", "speak")):
        out[f"{model}/{s}"] = m.score(f"{E}/{mf}/manifest.jsonl", f"{E}/results/{model}_{s}.jsonl")
json.dump(out, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "results_summary.json"), "w"), indent=1, ensure_ascii=False)
for k, v in out.items():
    for g, r in v.items(): print(k, "|", g.split(" / ")[1], "n", r["n"], "CERraw", r["cer_raw"], "CERcut", r["cer_cut"], "CERkeepZW", r["cer_keepzw_raw"], "WERcut", r["wer_cut"], "runaway", r["runaway_clips"], "latin ref/hyp", r["ref_latin_frac"], r["hyp_latin_frac"])
