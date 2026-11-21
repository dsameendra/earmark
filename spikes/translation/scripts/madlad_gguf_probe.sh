#!/bin/zsh
# Apache-2.0 weights (google/madlad400-3b-mt, jbochi GGUF q4k 1.65 GB). Prompt: "<2en> <sinhala text>" / "<2si> <english text>".
# CAUTION: the HF MADLAD GGUFs are documented for candle (quantized-t5 example), not llama.cpp; loading here may fail (unverified). Alternative: cargo run --example quantized-t5 --release -- --model-id jbochi/madlad400-3b-mt --weight-file model-q4k.gguf --prompt "<2en> ..."
# Needs llama.cpp built with Metal (brew install llama.cpp). T5 encoder-decoder GGUF support: verify with `llama-cli --version`.
# usage: madlad_gguf_probe.sh /path/to/model-q4k.gguf
M="$1"
llama-cli -m "$M" -ngl 99 -no-cnv -n 128 -p "<2en> අපිට අයවැය සමාලෝචනය කරන්න පුළුවන්ද?"
llama-cli -m "$M" -ngl 99 -no-cnv -n 128 -p "<2si> Can we review the budget?"
