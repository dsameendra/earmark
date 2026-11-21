# CC-BY-NC weights: RESEARCH / spot-check only.
# venv: python -m venv v && v/bin/pip install ctranslate2 transformers sentencepiece huggingface_hub
# usage: python -I nllb_ct2_probe.py <model_dir_for_ct2_int8> [bench]
# convert: ct2-transformers-converter --model facebook/nllb-200-distilled-600M --quantization int8 --output_dir <dir>
import sys, time, ctranslate2, transformers
d = sys.argv[1]; bench = len(sys.argv) > 2
tok = transformers.AutoTokenizer.from_pretrained("facebook/nllb-200-distilled-600M", src_lang="sin_Sinh")
tr = ctranslate2.Translator(d, device="cpu", compute_type="int8")  # CT2 has no Metal/ANE backend
SI = ["ඔබට සුබ උදෑසනක්!", "රැස්වීම මිනිත්තු පහකින් ආරම්භ වේ.", "අපිට අයවැය සමාලෝචනය කරන්න පුළුවන්ද?"]
src = [tok.convert_ids_to_tokens(tok.encode(s)) for s in SI]
t0 = time.time()
res = tr.translate_batch(src, target_prefix=[["eng_Latn"]] * len(src), beam_size=4)
for r in res: print(tok.decode(tok.convert_tokens_to_ids(r.hypotheses[0][1:])))
if bench: print("sec", time.time() - t0)
