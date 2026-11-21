# Converting an HF Whisper fine-tune to WhisperKit CoreML (NOT executed in Phase 0)

Why not executed: whisperkittools pins `torch==2.5.0`, `transformers==4.53`, `numpy<2.4.0` (setup.py on main, fetched 2026-11-21).
torch 2.5.0 has no wheels for Python 3.14/3.15, the only interpreters on this machine apart from the system 3.9, so a Python 3.11 would have to be installed (outside the allowed write paths for this spike).

Steps (per whisperkittools README, MIT):
1. Fresh Python 3.11 venv, `git clone https://github.com/argmaxinc/whisperkittools` (inspect before installing), `pip install -e .`
2. `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer` if `coremlcompiler` is not found.
3. Full fine-tunes (e.g. SinhaSpeech/whisper-small-sinhala-run12-best): `whisperkit-generate-model --model-version <hf-repo-or-local-dir> --output-dir ./out` (add `--generate-quantized-variants` etc. as listed in `-h`).
4. LoRA adapters (e.g. SPEAK-ASR/whisper-si-exp-10-medium-all): merge first with PEFT (`merge_and_unload()`, save full HF checkpoint), then step 3.
5. Validate: run WhisperKit (`whisperkit-cli transcribe --model-path ./out --language si`) on the manifests and compare CER with the PyTorch numbers; tolerate small deltas, reject if CER differs by more than ~1 point absolute.
Risks: tokenizer/added-token differences in fine-tunes; `generation_config` language/task forcing; WhisperKit decoder compute-unit placement on ANE vs GPU; fp16 rounding on small fine-tunes; the README does not describe fine-tunes or LoRA explicitly.
