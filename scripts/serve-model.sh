#!/bin/bash
#
# 開発用: 取得済みモデルを llama-server（OpenAI 互換 API）で起動する。
#
#   scripts/serve-model.sh <MODEL_ID> [--port N] [-- <llama-server の追加引数...>]
#
# - format: gguf        → .models/<MODEL_ID>/ の .gguf を使う
# - format: safetensors → .models/derived/<MODEL_ID>-*.gguf を使う（scripts/convert-model-gguf.sh で作成）
# - モデルごとの既定値: zenz-* はコンテキスト 1024、qwen3-* は思考モードを無効化（--reasoning off）
# - 127.0.0.1 でのみ待ち受ける。Kanato の設定に入力する値を起動時に表示する
# これは開発用の外部推論サーバーであり、アプリ内のローカル推論（LocalModelBackend）ではない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Kanato/LocalModels/model-manifest.json"
MODELS_ROOT="$REPO_ROOT/.models"
PORT="8801"
MODEL_ID=""
EXTRA=()

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="${2:?}"; shift 2 ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option: $1" >&2; usage 64 ;;
        *) [[ -z "$MODEL_ID" ]] || usage 64; MODEL_ID="$1"; shift ;;
    esac
done
[[ -n "$MODEL_ID" ]] || usage 64
[[ "$MODEL_ID" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] || die "Model ID が不正です: $MODEL_ID"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "ポートが不正です: $PORT"
command -v llama-server >/dev/null || die "llama-server が見つかりません（brew install llama.cpp）"

MODEL_JSON="$(jq -c --arg id "$MODEL_ID" '.models[] | select(.id == $id)' "$MANIFEST")"
[[ -n "$MODEL_JSON" ]] || die "マニフェストに $MODEL_ID がありません"
[[ -f "$MODELS_ROOT/$MODEL_ID/.kanato-install.json" ]] ||
    die "$MODEL_ID が取得されていません。先に scripts/download-model.sh $MODEL_ID を実行してください"

case "$(jq -r .format <<<"$MODEL_JSON")" in
    gguf)
        GGUF="$MODELS_ROOT/$MODEL_ID/$(jq -r '[.files[].path | select(endswith(".gguf"))][0] // empty' <<<"$MODEL_JSON")"
        ;;
    safetensors)
        GGUF="$(ls "$MODELS_ROOT/derived/$MODEL_ID"-*.gguf 2>/dev/null | head -1 || true)"
        [[ -n "$GGUF" ]] || die "GGUF がありません。先に scripts/convert-model-gguf.sh $MODEL_ID を実行してください"
        ;;
    *) die "llama-server で扱えない形式です" ;;
esac
[[ -f "$GGUF" ]] || die "GGUF が見つかりません: $GGUF"

ARGS=(-m "$GGUF" --host 127.0.0.1 --port "$PORT" --alias "$MODEL_ID")
API_FORMAT="Chat Completions（汎用LLM）"
case "$MODEL_ID" in
    zenz-*) ARGS+=(-c 1024); API_FORMAT="zenz（かな漢字変換モデル）" ;;
    qwen3-*) ARGS+=(-c 8192 --reasoning off) ;;
    *) ARGS+=(-c 8192) ;;
esac

cat <<INFO
Serving $MODEL_ID (development only)
  Model:   $GGUF
  Kanato の設定: モード External / API形式 $API_FORMAT
                 API Base URL http://127.0.0.1:$PORT/v1 / Model ID $MODEL_ID
INFO
exec llama-server "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
