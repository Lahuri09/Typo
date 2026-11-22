#!/bin/bash
set -euo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
source_root="${TYPO_LOCAL_AI_ROOT:-$HOME/Library/Application Support/Typo/LocalAI}"
destination="$1"
manifest="manifests/registry.ollama.ai/library/qwen2.5/1.5b"
TYPO_LOCAL_AI_ROOT="$source_root" "$base/Scripts/setup-local-ai.sh"
mkdir -p "$destination"
shopt -s nullglob
for component in ollama llama-server whisper-cli ggml-base.bin XGRAMMAR_NOTICE; do
    if [[ -e "$source_root/$component" ]]; then
        ditto "$source_root/$component" "$destination/$component"
    fi
done
if [[ -d "$source_root/GigaAM" ]]; then
    ditto "$source_root/GigaAM" "$destination/GigaAM"
fi
for component in "$source_root"/*.dylib "$source_root"/*.so "$source_root"/mlx_metal_* "$source_root"/*LICENSE*; do
    name="${component##*/}"
    if [[ -L "$component" ]]; then ln -sf "$(readlink "$component")" "$destination/$name"
    else ditto "$component" "$destination/$name"
    fi
done

models="$destination/ollama-models"
mkdir -p "$models/blobs" "$models/${manifest%/*}"
install -m 644 "$source_root/ollama-models/$manifest" "$models/$manifest"
digests="$(python3 - "$models/$manifest" <<'PY'
import json, re, sys
with open(sys.argv[1]) as file:
    manifest = json.load(file)
for item in [manifest["config"], *manifest["layers"]]:
    digest = item["digest"]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Invalid model digest")
    print(digest.replace(":", "-"))
PY
)"
while IFS= read -r blob; do
    cp -p "$source_root/ollama-models/blobs/$blob" "$models/blobs/$blob"
done <<< "$digests"

curl -fsSL --retry 3 https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/LICENSE -o "$destination/WHISPER_CPP_LICENSE"
curl -fsSL --retry 3 https://raw.githubusercontent.com/openai/whisper/v20250625/LICENSE -o "$destination/WHISPER_MODEL_LICENSE"
curl -fsSL --retry 3 https://raw.githubusercontent.com/ollama/ollama/v0.40.17/LICENSE -o "$destination/OLLAMA_LICENSE"
