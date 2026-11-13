#!/bin/bash
#
# 開発用: Hugging Face 形式（safetensors）のモデルを llama.cpp 用の GGUF に変換する。
#
#   scripts/convert-model-gguf.sh <MODEL_ID> [--outtype f16|bf16|q8_0] [--pre-tokenizer NAME]
#
# - 入力: scripts/download-model.sh で取得・検証済みの .models/<MODEL_ID>/（format: safetensors）
# - 出力: .models/derived/<MODEL_ID>-<outtype>.gguf（Git 管理外。マニフェストの管理対象外の派生物）
# - 変換スクリプトは、インストール済みの llama-server と同じコミットの llama.cpp を取得して使う
#   （.models/.tools/llama.cpp-<commit>/ に uv で専用の Python 環境を作る）
# - zenz-* は前処理の自動判定ができないため、既定で --pre-tokenizer gpt-2 を使う
# 依存: jq, git, curl, uv, llama-server（Homebrew の llama.cpp）
# 環境変数 LLAMA_CPP_COMMIT でコミットを明示できる

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Kanato/LocalModels/model-manifest.json"
MODELS_ROOT="$REPO_ROOT/.models"
OUTTYPE="f16"
PRE_TOKENIZER=""
MODEL_ID=""

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --outtype) OUTTYPE="${2:?}"; shift 2 ;;
        --pre-tokenizer) PRE_TOKENIZER="${2:?}"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option: $1" >&2; usage 64 ;;
        *) [[ -z "$MODEL_ID" ]] || usage 64; MODEL_ID="$1"; shift ;;
    esac
done
[[ -n "$MODEL_ID" ]] || usage 64
[[ "$MODEL_ID" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] || die "Model ID が不正です: $MODEL_ID"
[[ "$OUTTYPE" =~ ^(f16|bf16|q8_0|f32)$ ]] || die "未対応の outtype です: $OUTTYPE"
for tool in jq git curl uv llama-server; do
    command -v "$tool" >/dev/null || die "$tool が見つかりません"
done

FORMAT="$(jq -r --arg id "$MODEL_ID" '.models[] | select(.id == $id) | .format' "$MANIFEST")"
[[ -n "$FORMAT" ]] || die "マニフェストに $MODEL_ID がありません"
[[ "$FORMAT" == "safetensors" ]] || die "$MODEL_ID は ${FORMAT} 形式です（変換対象は safetensors のみ）"

MODEL_DIR="$MODELS_ROOT/$MODEL_ID"
[[ -f "$MODEL_DIR/.kanato-install.json" ]] ||
    die "$MODEL_ID が取得されていません。先に scripts/download-model.sh $MODEL_ID を実行してください"

if [[ -z "$PRE_TOKENIZER" && "$MODEL_ID" == zenz-* ]]; then
    PRE_TOKENIZER="gpt-2"
fi

# --- インストール済み llama.cpp と同じコミットの変換スクリプトを用意する ---
COMMIT="${LLAMA_CPP_COMMIT:-}"
if [[ -z "$COMMIT" ]]; then
    short="$(llama-server --version 2>&1 | sed -n 's/.*commit \([0-9a-f]\{7,40\}\).*/\1/p' | head -1)"
    [[ -n "$short" ]] || die "llama-server のコミットを判定できません。LLAMA_CPP_COMMIT を指定してください"
    COMMIT="$(curl -fsS "https://api.github.com/repos/ggml-org/llama.cpp/commits/$short" | jq -r .sha)"
fi
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "llama.cpp のコミットが不正です: $COMMIT"

TOOLS="$MODELS_ROOT/.tools/llama.cpp-$COMMIT"
if [[ ! -f "$TOOLS/.ready" ]]; then
    echo "Preparing llama.cpp converter ($COMMIT) -> $TOOLS"
    rm -rf "$TOOLS"
    mkdir -p "$TOOLS"
    git init -q "$TOOLS/src"
    git -C "$TOOLS/src" fetch -q --depth 1 https://github.com/ggml-org/llama.cpp "$COMMIT"
    git -C "$TOOLS/src" checkout -q FETCH_HEAD
    uv venv -q -p 3.12 "$TOOLS/venv"
    # requirements-convert_hf_to_gguf.txt と同じ制約。gguf はソース同梱版を使う
    VIRTUAL_ENV="$TOOLS/venv" uv pip install -q \
        --extra-index-url https://download.pytorch.org/whl/cpu \
        -r "$TOOLS/src/requirements/requirements-convert_hf_to_gguf.txt" "$TOOLS/src/gguf-py"
    touch "$TOOLS/.ready"
fi

# --- 変換（一時ファイルへ書き出してから配置する） ---
mkdir -p "$MODELS_ROOT/derived"
OUT="$MODELS_ROOT/derived/$MODEL_ID-$OUTTYPE.gguf"
TMP_OUT="$OUT.partial"
trap 'rm -f "$TMP_OUT"' EXIT

echo "Converting $MODEL_ID ($OUTTYPE${PRE_TOKENIZER:+, pre-tokenizer: $PRE_TOKENIZER})"
KANATO_PRE_TOKENIZER="$PRE_TOKENIZER" "$TOOLS/venv/bin/python" \
    "$REPO_ROOT/scripts/lib/convert_hf_to_gguf_wrapper.py" "$TOOLS/src" \
    "$MODEL_DIR" --outtype "$OUTTYPE" --outfile "$TMP_OUT" 2>&1 |
    tr '\r' '\n' | grep -vE 'hf-to-gguf:(blk|gguf: )|^Writing:|^ *$' || true
[[ -s "$TMP_OUT" ]] || die "変換に失敗しました"
mv "$TMP_OUT" "$OUT"
echo "converted: $OUT"
