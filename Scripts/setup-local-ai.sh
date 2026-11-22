#!/bin/bash
set -euo pipefail
umask 077

root="${TYPO_LOCAL_AI_ROOT:-$HOME/Library/Application Support/Typo/LocalAI}"
work="$(mktemp -d)"
ollama_pid=""
cleanup() {
    if [[ -n "$ollama_pid" ]]; then kill "$ollama_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$root"
export OLLAMA_HOST=127.0.0.1:11439 OLLAMA_NO_CLOUD=1
export OLLAMA_MODELS="$root/ollama-models"

install_text() {
    if [[ ! -x "$root/ollama" ]]; then
        curl -fL --retry 3 https://github.com/ollama/ollama/releases/download/v0.40.17/ollama-darwin.tgz -o "$work/ollama.tgz"
        mkdir "$work/ollama"
        tar -xf "$work/ollama.tgz" -C "$work/ollama"
        ditto "$work/ollama" "$root"
    fi
    if [[ -f "$OLLAMA_MODELS/manifests/registry.ollama.ai/library/qwen2.5/1.5b" ]]; then return; fi
    if ! curl --noproxy '*' -fsS "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
        "$root/ollama" serve > "$work/ollama.log" 2>&1 &
        ollama_pid=$!
        for ((attempt=0; attempt<50; attempt++)); do
            if curl --noproxy '*' -fsS "http://$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then break; fi
            sleep 0.2
        done
    fi
    "$root/ollama" pull qwen2.5:1.5b
}

install_speech() {
    if [[ ! -x "$root/whisper-cli" ]]; then
        local cmake_bin
        if command -v cmake >/dev/null; then
            cmake_bin="$(command -v cmake)"
        elif command -v uvx >/dev/null; then
            cmake_bin="$(command -v uvx)"
        else
            echo 'Для сборки whisper.cpp установите CMake или uv.' >&2
            return 1
        fi
        local cmake_cmd=("$cmake_bin")
        if [[ "${cmake_bin##*/}" == uvx ]]; then cmake_cmd+=(--from cmake cmake); fi
        curl -fL --retry 3 https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.5 -o "$work/whisper.tar.gz"
        tar -xf "$work/whisper.tar.gz" -C "$work"
        "${cmake_cmd[@]}" -S "$work/whisper.cpp-1.9.5" -B "$work/build" \
            -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF \
            -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF
        "${cmake_cmd[@]}" --build "$work/build" --target whisper-cli --parallel 4
        install -m 755 "$work/build/bin/whisper-cli" "$root/whisper-cli"
    fi
    if [[ ! -f "$root/ggml-base.bin" ]]; then
        curl -fL --retry 3 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin -o "$work/ggml-base.bin"
        mv "$work/ggml-base.bin" "$root/ggml-base.bin"
    fi
}

install_gigaam() {
    if [[ "$(uname -m)" != arm64 ]]; then return; fi
    local destination="$root/GigaAM"
    if [[ -x "$destination/sherpa-onnx-offline" && -s "$destination/libonnxruntime.dylib" &&
          -s "$destination/model.int8.onnx" && -s "$destination/tokens.txt" &&
          -s "$destination/GIGAAM_LICENSE" && -s "$destination/SHERPA_LICENSE" &&
          -s "$destination/ONNXRUNTIME_LICENSE" && -s "$destination/ONNXRUNTIME_NOTICES.txt" ]]; then return; fi

    local sherpa="sherpa-onnx-v2.0.2-osx-arm64-shared-no-tts"
    local model="https://huggingface.co/csukuangfj/sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16/resolve/4fb5407ff028a69fec516cdf4c10fac9ddea7c16"
    local ort="https://cdn.jsdelivr.net/gh/microsoft/onnxruntime@v1.28.2"
    mkdir -p "$work/GigaAM"
    curl -fsSL --retry 3 "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.2/$sherpa.tar.bz2" -o "$work/sherpa.tar.bz2"
    printf '%s  %s\n' 1a803809572335ef545978b62b0271ad119969fef6f9153a94c174c3adc95608 "$work/sherpa.tar.bz2" | shasum -a 256 -c
    tar -xf "$work/sherpa.tar.bz2" -C "$work"
    install -m 755 "$work/$sherpa/bin/sherpa-onnx-offline" "$work/GigaAM/"
    install -m 644 "$work/$sherpa/lib/libonnxruntime.dylib" "$work/GigaAM/"
    curl -fsSL --retry 3 "$model/model.int8.onnx" -o "$work/GigaAM/model.int8.onnx"
    printf '%s  %s\n' d5fea8df94263c285e54b21e5774b707c707192d3bdbeffd7b1eb07fb6743b35 "$work/GigaAM/model.int8.onnx" | shasum -a 256 -c
    curl -fsSL --retry 3 "$model/tokens.txt" -o "$work/GigaAM/tokens.txt"
    curl -fsSL --retry 3 "$model/LICENSE" -o "$work/GigaAM/GIGAAM_LICENSE"
    curl -fsSL --retry 3 https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.2/LICENSE -o "$work/GigaAM/SHERPA_LICENSE"
    curl -fsSL --retry 3 "$ort/LICENSE" -o "$work/GigaAM/ONNXRUNTIME_LICENSE"
    curl -fsSL --retry 3 "$ort/ThirdPartyNotices.txt" -o "$work/GigaAM/ONNXRUNTIME_NOTICES.txt"
    ditto "$work/GigaAM" "$destination"
}

case "${1:-all}" in
    text) install_text ;;
    speech) install_speech; install_gigaam ;;
    all) install_speech; install_gigaam; install_text ;;
    *) echo 'Usage: setup-local-ai.sh [all|speech|text]' >&2; exit 2 ;;
esac
