# venv: python -m venv v && v/bin/pip install mlx-lm
# usage: python -I mlx_llm_probe.py mlx-community/gemma-3-12b-it-4bit   (Gemma terms)
#        python -I mlx_llm_probe.py mlx-community/Qwen3-8B-4bit           (Apache-2.0; verify repo exists)
# HF_HOME must point into .model-cache/translation/<name>. Quality spot check only.
import sys
from mlx_lm import load, generate
m, t = load(sys.argv[1])
def tr(text, a, b):
    msg = [{"role": "user", "content": f"Translate from {a} to {b}. Output only the translation.\n\n{text}"}]
    p = t.apply_chat_template(msg, add_generation_prompt=True, tokenize=False)
    return generate(m, t, prompt=p, max_tokens=200)
print(tr("අපිට අයවැය සමාලෝචනය කරන්න පුළුවන්ද?", "Sinhala", "English"))
print(tr("Can we review the budget before Friday's meeting?", "English", "Sinhala"))
