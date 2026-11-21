"""Download pinned model snapshots into the shared cache (weights/config/tokenizer only, no code execution)."""
import sys
from huggingface_hub import snapshot_download, HfApi
for repo in sys.argv[1:]:
    sha = HfApi().model_info(repo).sha
    p = snapshot_download(repo, revision=sha, allow_patterns=["*.json", "*.txt", "*.safetensors", "*.md", "LICENSE*"], ignore_patterns=["last-checkpoint/*", "*/optimizer*", "images/*"])
    print(repo, sha, p, flush=True)
