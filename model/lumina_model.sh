#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_ROOT="$ROOT_DIR/model"
APP_MODELS_DIR="$ROOT_DIR/app/Resources/Models"
VALIDATOR="$MODEL_ROOT/validate_minicpmv46_bundle.py"
HF_BIN="${HF_BIN:-hf}"

ORIGINAL_BUNDLE_DIR="${LUMINA_ORIGINAL_BUNDLE_DIR:-$MODEL_ROOT/bundles/original/MiniCPMV46ReActModel}"
TRAINED_BUNDLE_DIR="${LUMINA_TRAINED_BUNDLE_DIR:-$MODEL_ROOT/bundles/trained/MiniCPMV46ReActModel-AgenticSFTDPO-Q8}"
EMBEDDING_DIR="${LUMINA_EMBEDDING_DIR:-$MODEL_ROOT/embeddings/BGETextEmbedding}"

ORIGINAL_APP_DIR="$APP_MODELS_DIR/MiniCPMV46ReActModel"
TRAINED_APP_DIR="$APP_MODELS_DIR/MiniCPMV46ReActModel-AgenticSFTDPO-Q8"
EMBEDDING_APP_DIR="$APP_MODELS_DIR/BGETextEmbedding.mlmodelc"
EMBEDDING_TOKENIZER_APP="$APP_MODELS_DIR/BGETextEmbedding-tokenizer.json"

BGE_REPO="${LUMINA_BGE_REPO:-zhufucdev/BAAI-bge-small-zh-v1.5}"
MINICPM_REPO="${LUMINA_MINICPMV46_REPO:-openbmb/MiniCPM-V-4_6-gguf}"
MINICPM_QUANT="${LUMINA_MINICPMV46_QUANT:-F16}"
MINICPM_CONTEXT_LENGTH="${LUMINA_MINICPMV46_CONTEXT_LENGTH:-16000}"
TEXT_MODEL_FILE="MiniCPM-V-4_6-${MINICPM_QUANT}.gguf"
PROJECTOR_FILE="mmproj-model-f16.gguf"

TRAINED_REMOTE="${LUMINA_TRAINED_REMOTE:-root@sh01-ssh.gpuhome.cc:/root/rivermind-data/lumina-agentic-training/artifacts/MiniCPMV46ReActModel-AgenticSFTDPO-Q8}"
TRAINED_REMOTE_PORT="${LUMINA_TRAINED_REMOTE_PORT:-30058}"

usage() {
  cat <<'USAGE'
Lumina model manager

Usage:
  model/lumina_model.sh download original     Download original MiniCPM-V 4.6 GGUF bundle into model/bundles/original
  model/lumina_model.sh download embedding    Download and compile BGE embedding model into model/embeddings
  model/lumina_model.sh download all          Download original + embedding
  model/lumina_model.sh pull-trained          Pull trained Agentic SFT+DPO bundle from the remote server
  model/lumina_model.sh build-native-engine   Build native MiniCPM-V 4.6 GGUF engine dylibs into model bundles
  model/lumina_model.sh validate original     Validate original MiniCPM-V bundle
  model/lumina_model.sh validate trained      Validate trained Agentic SFT+DPO bundle
  model/lumina_model.sh validate PATH         Validate a MiniCPM-V bundle path
  model/lumina_model.sh install original      Install original MiniCPM-V bundle into app/Resources/Models
  model/lumina_model.sh install trained       Install trained Agentic SFT+DPO bundle into app/Resources/Models
  model/lumina_model.sh install embedding     Install embedding model into app/Resources/Models
  model/lumina_model.sh install all           Install original + trained + embedding
  model/lumina_model.sh paths                 Print source and app model paths

Environment:
  HF_BIN                         Hugging Face CLI binary, default: hf
  LUMINA_SKIP_NATIVE_ENGINE=1    Skip native MiniCPM engine build after original download
  LUMINA_BGE_REPO                Embedding repo, default: zhufucdev/BAAI-bge-small-zh-v1.5
  LUMINA_MINICPMV46_REPO         Original GGUF repo, default: openbmb/MiniCPM-V-4_6-gguf
  LUMINA_MINICPMV46_QUANT        Original quant, default: F16
  LUMINA_TRAINED_REMOTE          rsync/scp-style trained bundle source
  LUMINA_TRAINED_REMOTE_PORT     SSH port for trained bundle source, default: 30058
USAGE
}

log() {
  printf '[Lumina model] %s\n' "$*"
}

die() {
  printf '[Lumina model] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

print_paths() {
  cat <<PATHS
MODEL_ROOT=$MODEL_ROOT
ORIGINAL_BUNDLE_DIR=$ORIGINAL_BUNDLE_DIR
TRAINED_BUNDLE_DIR=$TRAINED_BUNDLE_DIR
EMBEDDING_DIR=$EMBEDDING_DIR
APP_MODELS_DIR=$APP_MODELS_DIR
ORIGINAL_APP_DIR=$ORIGINAL_APP_DIR
TRAINED_APP_DIR=$TRAINED_APP_DIR
EMBEDDING_APP_DIR=$EMBEDDING_APP_DIR
PATHS
}

validate_minicpm_bundle() {
  local bundle="$1"
  [[ -x "$VALIDATOR" ]] || die "Missing validator: $VALIDATOR"
  "$VALIDATOR" "$bundle" --expected-context "$MINICPM_CONTEXT_LENGTH"
}

sync_dir() {
  local source="$1"
  local target="$2"
  [[ -d "$source" ]] || die "Source directory does not exist: $source"
  mkdir -p "$target"
  rsync -a --delete "$source/" "$target/"
}

build_native_engine() {
  local engine_src="$ROOT_DIR/app/NativeEngines/MiniCPMV46/LuminaMiniCPMV46GGUFEngine.cpp"
  local llama_dir="${LUMINA_LLAMA_CPP_DIR:-$ROOT_DIR/.build/vendor/llama.cpp}"
  local llama_repo="${LUMINA_LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
  local llama_build_dir="$llama_dir/build"
  local default_model_dir="$ORIGINAL_APP_DIR"
  local agentic_dpo_model_dir="$TRAINED_APP_DIR"
  local model_dirs=()

  if [[ -n "${LUMINA_MINICPMV46_INSTALL_DIRS:-}" ]]; then
    IFS=: read -r -a model_dirs <<< "$LUMINA_MINICPMV46_INSTALL_DIRS"
  elif [[ -n "${LUMINA_MINICPMV46_OUTPUT_DIR:-}" ]]; then
    model_dirs=("$LUMINA_MINICPMV46_OUTPUT_DIR")
  else
    model_dirs=("$default_model_dir")
    if [[ -d "$agentic_dpo_model_dir" ]]; then
      model_dirs+=("$agentic_dpo_model_dir")
    fi
  fi

  local build_output_dir="${model_dirs[0]}"
  local output_dylib="$build_output_dir/libLuminaMiniCPMV46GGUFEngine.dylib"

  [[ -f "$engine_src" ]] || die "Missing native engine source: $engine_src"
  need_cmd git
  need_cmd cmake
  need_cmd c++

  if [[ ! -d "$llama_dir/.git" ]]; then
    log "Cloning llama.cpp library sources into .build"
    rm -rf "$llama_dir"
    git clone --depth 1 "$llama_repo" "$llama_dir"
  fi

  local qwen35_src="$llama_dir/src/models/qwen35.cpp"
  if [[ -f "$qwen35_src" ]]; then
    python3 - "$qwen35_src" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "qwen35 metadata declares"
needle = "void llama_model_qwen35::load_arch_tensors(llama_model_loader & ml) {\n"
insert = r'''    if (hparams.nextn_predict_layers > 0) {
        const uint32_t n_main = hparams.n_layer - hparams.nextn_predict_layers;
        const std::string first_mtp_block = format("blk.%u.attn_norm.weight", n_main);
        const std::string first_mtp_nextn = format("blk.%u.nextn.eh_proj.weight", n_main);

        if (ml.get_weight(first_mtp_block.c_str()) == nullptr &&
            ml.get_weight(first_mtp_nextn.c_str()) == nullptr) {
            LLAMA_LOG_WARN(
                "%s: qwen35 metadata declares %u NextN/MTP layer(s), but no MTP tensors were found at block %u; "
                "loading the %u-layer main trunk only\n",
                __func__,
                hparams.nextn_predict_layers,
                n_main,
                n_main
            );
            hparams.n_layer = n_main;
            hparams.nextn_predict_layers = 0;
        }
    }

'''

if marker not in text:
    if needle not in text:
        raise SystemExit(f"[Lumina model] qwen35.cpp patch point not found: {path}")
    path.write_text(text.replace(needle, needle + insert, 1))
PY
  fi

  log "Building llama.cpp library backend with Metal + Accelerate"
  cmake -S "$llama_dir" -B "$llama_build_dir" \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_ACCELERATE=ON \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$llama_build_dir" --target llama -j "$(sysctl -n hw.logicalcpu)" >/dev/null

  mkdir -p "$build_output_dir"
  log "Building MiniCPM-V 4.6 native GGUF engine"
  c++ -std=c++17 -O3 -fPIC -dynamiclib "$engine_src" \
    -I"$llama_dir/include" \
    -I"$llama_dir/ggml/include" \
    -L"$llama_build_dir/bin" \
    -lllama -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas \
    -framework Foundation -framework Metal -framework Accelerate \
    -Wl,-rpath,@loader_path \
    -o "$output_dylib"

  copy_engine_outputs() {
    local target_dir="$1"
    mkdir -p "$target_dir"
    local target_engine="$target_dir/libLuminaMiniCPMV46GGUFEngine.dylib"
    if [[ "$output_dylib" != "$target_engine" ]]; then
      cp "$output_dylib" "$target_engine"
    fi
    for dylib in \
      libllama.0.dylib \
      libggml.0.dylib \
      libggml-base.0.dylib \
      libggml-cpu.0.dylib \
      libggml-metal.0.dylib \
      libggml-blas.0.dylib
    do
      cp "$llama_build_dir/bin/$dylib" "$target_dir/$dylib"
    done
    if [[ -f "$target_dir/model.gguf" ]]; then
      log "Installed native engine into model bundle: $target_dir"
    else
      printf '[Lumina model] Installed native engine into %s (warning: model.gguf not present yet)\n' "$target_dir" >&2
    fi
  }

  for dylib in \
    libllama.0.dylib \
    libggml.0.dylib \
    libggml-base.0.dylib \
    libggml-cpu.0.dylib \
    libggml-metal.0.dylib \
    libggml-blas.0.dylib
  do
    cp "$llama_build_dir/bin/$dylib" "$build_output_dir/$dylib"
  done

  if command -v install_name_tool >/dev/null 2>&1; then
    install_name_tool -id @rpath/libLuminaMiniCPMV46GGUFEngine.dylib "$output_dylib" || true
  fi

  local sign_identity="${LUMINA_CODESIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}}"
  if [[ -z "$sign_identity" || "$sign_identity" == "-" ]]; then
    sign_identity="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ { print $2; exit }'
    )"
  fi

  if [[ -n "$sign_identity" && "$sign_identity" != "-" ]]; then
    log "Signing MiniCPM-V 4.6 native engine dylibs with $sign_identity"
    for model_dir in "${model_dirs[@]}"; do
      copy_engine_outputs "$model_dir"
      for dylib in "$model_dir"/*.dylib; do
        codesign --force --sign "$sign_identity" --timestamp=none "$dylib"
      done
    done
  else
    printf '[Lumina model] Skipping native engine dylib signing; set LUMINA_CODESIGN_IDENTITY to enable hardened-runtime loading.\n' >&2
    for model_dir in "${model_dirs[@]}"; do
      copy_engine_outputs "$model_dir"
    done
  fi

  log "Native engine ready in:"
  for model_dir in "${model_dirs[@]}"; do
    printf '  - %s/libLuminaMiniCPMV46GGUFEngine.dylib\n' "$model_dir"
  done
}

download_original() {
  need_cmd "$HF_BIN"
  local staging="$MODEL_ROOT/.staging/MiniCPMV46ReActModel"
  rm -rf "$staging"
  mkdir -p "$staging" "$ORIGINAL_BUNDLE_DIR"

  log "Downloading original MiniCPM-V 4.6 GGUF assets: $MINICPM_REPO / $TEXT_MODEL_FILE"
  "$HF_BIN" download "$MINICPM_REPO" \
    --include "$TEXT_MODEL_FILE" \
    --include "$PROJECTOR_FILE" \
    --local-dir "$staging"

  rm -rf "$ORIGINAL_BUNDLE_DIR"
  mkdir -p "$ORIGINAL_BUNDLE_DIR"
  mv "$staging/$TEXT_MODEL_FILE" "$ORIGINAL_BUNDLE_DIR/model.gguf"
  mv "$staging/$PROJECTOR_FILE" "$ORIGINAL_BUNDLE_DIR/$PROJECTOR_FILE"

  python3 - "$ORIGINAL_BUNDLE_DIR" "$MINICPM_CONTEXT_LENGTH" "$MINICPM_QUANT" "$MINICPM_REPO" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
context = int(sys.argv[2])
quant = sys.argv[3]
repo = sys.argv[4]
model_config = {
    "model_name": "MiniCPM-V 4.6",
    "architecture": "minicpm-v-4_6",
    "context_length": context,
    "quantization": quant,
    "text_model": "model.gguf",
    "vision_projector": "mmproj-model-f16.gguf",
    "source_repo": repo,
    "runtime": "LuminaModelRuntimeCore native C++",
    "macos_acceleration": "MPS backend",
    "ios_acceleration": "ANE backend",
}
(root / "model_config.json").write_text(
    json.dumps(model_config, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

  validate_minicpm_bundle "$ORIGINAL_BUNDLE_DIR"

  if [[ "${LUMINA_SKIP_NATIVE_ENGINE:-0}" != "1" ]]; then
    LUMINA_MINICPMV46_OUTPUT_DIR="$ORIGINAL_BUNDLE_DIR" build_native_engine
  else
    log "Skipping native engine build because LUMINA_SKIP_NATIVE_ENGINE=1"
  fi
  rm -rf "$staging"
}

download_embedding() {
  need_cmd "$HF_BIN"
  need_cmd xcrun
  local staging="$MODEL_ROOT/.staging/BGETextEmbedding"
  rm -rf "$staging"
  mkdir -p "$staging" "$EMBEDDING_DIR"

  log "Downloading BGE embedding model: $BGE_REPO"
  "$HF_BIN" download "$BGE_REPO" \
    --include 'CoreML/model.mlpackage/**' \
    --include 'tokenizer.json' \
    --local-dir "$staging"

  log "Compiling BGE Core ML package"
  rm -rf "$staging/Compiled"
  xcrun coremlcompiler compile "$staging/CoreML/model.mlpackage" "$staging/Compiled" >/dev/null

  rm -rf "$EMBEDDING_DIR/BGETextEmbedding.mlmodelc" "$EMBEDDING_DIR/BGETextEmbedding-tokenizer.json"
  mv "$staging/Compiled/model.mlmodelc" "$EMBEDDING_DIR/BGETextEmbedding.mlmodelc"
  mv "$staging/tokenizer.json" "$EMBEDDING_DIR/BGETextEmbedding-tokenizer.json"
  rm -rf "$staging"
}

pull_trained() {
  need_cmd rsync
  mkdir -p "$TRAINED_BUNDLE_DIR"
  log "Pulling trained bundle from $TRAINED_REMOTE"
  rsync -a --delete -e "ssh -p $TRAINED_REMOTE_PORT" "$TRAINED_REMOTE/" "$TRAINED_BUNDLE_DIR/"
}

install_original() {
  validate_minicpm_bundle "$ORIGINAL_BUNDLE_DIR"
  sync_dir "$ORIGINAL_BUNDLE_DIR" "$ORIGINAL_APP_DIR"
  log "Installed original model into $ORIGINAL_APP_DIR"
}

install_trained() {
  [[ -f "$TRAINED_BUNDLE_DIR/model.gguf" ]] || die "Trained model bundle is missing model.gguf: $TRAINED_BUNDLE_DIR"
  [[ -f "$TRAINED_BUNDLE_DIR/model_config.json" ]] || die "Trained model bundle is missing model_config.json: $TRAINED_BUNDLE_DIR"
  sync_dir "$TRAINED_BUNDLE_DIR" "$TRAINED_APP_DIR"
  log "Installed trained model into $TRAINED_APP_DIR"
}

install_embedding() {
  [[ -d "$EMBEDDING_DIR/BGETextEmbedding.mlmodelc" ]] || die "Embedding model is missing: $EMBEDDING_DIR/BGETextEmbedding.mlmodelc"
  [[ -f "$EMBEDDING_DIR/BGETextEmbedding-tokenizer.json" ]] || die "Embedding tokenizer is missing: $EMBEDDING_DIR/BGETextEmbedding-tokenizer.json"
  mkdir -p "$APP_MODELS_DIR"
  rm -rf "$EMBEDDING_APP_DIR"
  rsync -a --delete "$EMBEDDING_DIR/BGETextEmbedding.mlmodelc/" "$EMBEDDING_APP_DIR/"
  cp "$EMBEDDING_DIR/BGETextEmbedding-tokenizer.json" "$EMBEDDING_TOKENIZER_APP"
  log "Installed embedding model into $EMBEDDING_APP_DIR"
}

download_target() {
  case "${1:-}" in
    original) download_original ;;
    embedding) download_embedding ;;
    all) download_original; download_embedding ;;
    *) usage; die "Unknown download target: ${1:-}" ;;
  esac
}

install_target() {
  case "${1:-}" in
    original) install_original ;;
    trained) install_trained ;;
    embedding) install_embedding ;;
    all) install_original; install_trained; install_embedding ;;
    *) usage; die "Unknown install target: ${1:-}" ;;
  esac
}

validate_target() {
  case "${1:-}" in
    original) validate_minicpm_bundle "$ORIGINAL_BUNDLE_DIR" ;;
    trained) validate_minicpm_bundle "$TRAINED_BUNDLE_DIR" ;;
    "") usage; die "Missing validate target" ;;
    *) validate_minicpm_bundle "$1" ;;
  esac
}

main() {
  case "${1:-}" in
    download) shift; download_target "${1:-}" ;;
    pull-trained) pull_trained ;;
    build-native-engine) build_native_engine ;;
    validate) shift; validate_target "${1:-}" ;;
    install) shift; install_target "${1:-}" ;;
    paths) print_paths ;;
    -h|--help|help|"") usage ;;
    *) usage; die "Unknown command: $1" ;;
  esac
}

main "$@"
