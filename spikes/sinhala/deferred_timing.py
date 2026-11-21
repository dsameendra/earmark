"""DEFERRED speed benchmark (NOT run in Phase 0 - machine was shared). Run on an otherwise idle machine, plugged in.
Measures per-clip wall time and real-time factor for the Python mlx-audio Qwen3-ASR Sinhala path and (optionally) HF Whisper on MPS.
Usage: python -I deferred_timing.py qwen MODEL_DIR MANIFEST [REPEATS]
       python -I deferred_timing.py whisper MODEL_DIR MANIFEST [REPEATS]
First pass is a warm-up and is discarded. Prints median / p90 seconds and RTF = proc_time / audio_time.
For WhisperKit (CoreML) timing use `whisperkit-cli transcribe --model-path <dir> --language si --audio-path <wav> --verbose` on the same manifest.
"""
import sys, json, time, statistics
kind, model_dir, manifest = sys.argv[1:4]; reps = int(sys.argv[4]) if len(sys.argv) > 4 else 3
rows = [json.loads(l) for l in open(manifest, encoding="utf8")]
if kind == "qwen":
    from mlx_audio.stt.utils import load_model
    m = load_model(model_dir)
    run = lambda r: m.generate(r["path"], max_tokens=int(64 + 30 * r["dur"]))
else:
    import torch, soundfile as sf
    from transformers import WhisperForConditionalGeneration, WhisperProcessor
    p = WhisperProcessor.from_pretrained(model_dir); m = WhisperForConditionalGeneration.from_pretrained(model_dir, torch_dtype=torch.float16).to("mps").eval()
    def run(r):
        x, _ = sf.read(r["path"], dtype="float32")
        f = p(x, sampling_rate=16000, return_tensors="pt").input_features.to("mps", torch.float16)
        out = m.generate(f, language="sinhala", task="transcribe", max_new_tokens=int(64 + 30 * r["dur"])); torch.mps.synchronize(); return out
run(rows[0])  # warm-up
t = []
for _ in range(reps):
    for r in rows:
        s = time.perf_counter(); run(r); t.append((time.perf_counter() - s, r["dur"]))
print("n", len(t), "median s", statistics.median(x for x, _ in t), "p90 s", sorted(x for x, _ in t)[int(.9 * len(t))], "RTF", sum(x for x, _ in t) / sum(d for _, d in t))
