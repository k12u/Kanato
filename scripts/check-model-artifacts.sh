#!/bin/bash
#
# モデルの重みファイルが Git・ソースフォルダ・配布物に混入していないかを検査する。
#
#   scripts/check-model-artifacts.sh                      Git とソースフォルダを検査
#   scripts/check-model-artifacts.sh path/to/Kanato.app   さらにビルド済みアプリを検査
#
# - Git 管理下に重みファイル・モデル保存ディレクトリがあればエラー
# - Kanato/ 等（Xcode の同期フォルダ。置いたファイルは自動でバンドルされる）に重みがあればエラー
# - アプリ内の重みファイルは、Contents/Resources/Models/<MODEL_ID>/ 配下かつ
#   マニフェストで redistribution == "verified" のモデルに限り許可（Embedded 用）。それ以外はエラー
# 終了コード: 0 = 問題なし / 1 = 混入あり
# 依存: jq, git

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Kanato/LocalModels/model-manifest.json"
APP_PATH="${1:-}"
# 重みファイルとして扱う拡張子（.gitignore と合わせる）
WEIGHT_PATTERN='\.(gguf|ggml|safetensors|bin|pt|pth|ckpt|onnx|npz|mlmodel|mlmodelc|mlpackage|tflite)$'
SYNCED_DIRS=(Kanato KanatoTests KanatoUITests)
failed=0

report() { echo "NG: $*" >&2; failed=1; }

cd "$REPO_ROOT"

# 1. Git 管理下
while IFS= read -r path; do
    [[ -n "$path" ]] && report "Git 管理下に重みファイルがあります: $path"
done < <(git ls-files | grep -Ei "$WEIGHT_PATTERN" || true)
while IFS= read -r path; do
    [[ -n "$path" ]] && report "Git 管理下にモデル保存ディレクトリのファイルがあります: $path"
done < <(git ls-files -- .models || true)

# 2. Xcode の同期フォルダ（置くだけで Copy Bundle Resources に入る）
for dir in "${SYNCED_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r path; do
        [[ -n "$path" ]] && report "ソースフォルダに重みファイルがあります（ビルドで同梱されます）: $path"
    done < <(find "$dir" \( -type f -o -type d \) | grep -Ei "$WEIGHT_PATTERN" || true)
    while IFS= read -r path; do
        [[ -n "$path" ]] && report "ソースフォルダにモデルのインストール記録があります: $path"
    done < <(find "$dir" -name '.kanato-install.json' || true)
done

# 3. ビルド済みアプリ
if [[ -n "$APP_PATH" ]]; then
    [[ -d "$APP_PATH" ]] || { echo "error: アプリが見つかりません: $APP_PATH" >&2; exit 2; }
    verified_ids="$(jq -r '.models[] | select(.license.redistribution == "verified") | .id' "$MANIFEST")"
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        rel="${path#"$APP_PATH"/}"
        if [[ "$rel" =~ ^Contents/Resources/Models/([^/]+)/ ]] &&
            grep -qxF "${BASH_REMATCH[1]}" <<<"$verified_ids"; then
            echo "ok: ライセンス確認済みモデル ${BASH_REMATCH[1]}: $rel"
        else
            report "配布物にライセンス未確認（またはマニフェスト外）の重みファイルがあります: $rel"
        fi
    done < <(find "$APP_PATH" \( -type f -o -type d \) | grep -Ei "$WEIGHT_PATTERN" || true)
    while IFS= read -r path; do
        [[ -n "$path" ]] && report "配布物に開発用のインストール記録があります: ${path#"$APP_PATH"/}"
    done < <(find "$APP_PATH" -name '.kanato-install.json' || true)
fi

if [[ $failed -eq 0 ]]; then
    echo "OK: モデルの重みファイルの混入はありません${APP_PATH:+（$APP_PATH を含む）}"
fi
exit $failed
