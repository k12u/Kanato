#!/bin/bash
#
# 開発用: Model Manifest に記載されたモデルを取得し、SHA-256 を検証して配置する。
#
#   scripts/download-model.sh --list                 マニフェストのモデル一覧
#   scripts/download-model.sh <MODEL_ID>             取得（既定の保存先: <repo>/.models/<MODEL_ID>）
#   scripts/download-model.sh --verify <MODEL_ID>    取得済みモデルのハッシュを再検証
#
# オプション:
#   --manifest PATH   マニフェスト（既定: Kanato/LocalModels/model-manifest.json）
#   --dest DIR        保存先ルート（既定: <repo>/.models。Git 管理外）
#
# 保存レイアウトとインストール記録（.kanato-install.json）はアプリの ModelManager と同じ。
# 一時ディレクトリ（<dest>/.staging）で全ファイルのサイズとハッシュを検証し、記録を書いてから
# 最終位置へ移動する。記録のないディレクトリは使用可能なモデルとして扱わない。
# 依存: jq, curl, shasum（macOS 標準）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Kanato/LocalModels/model-manifest.json"
DEST_ROOT="$REPO_ROOT/.models"
RECEIPT_NAME=".kanato-install.json"
MODE="download"
MODEL_ID=""

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST="${2:?--manifest requires a path}"; shift 2 ;;
        --dest) DEST_ROOT="${2:?--dest requires a directory}"; shift 2 ;;
        --list) MODE="list"; shift ;;
        --verify) MODE="verify"; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option: $1" >&2; usage 64 ;;
        *) [[ -z "$MODEL_ID" ]] || usage 64; MODEL_ID="$1"; shift ;;
    esac
done

for tool in jq curl shasum; do
    command -v "$tool" >/dev/null || die "$tool が見つかりません"
done
[[ -f "$MANIFEST" ]] || die "マニフェストがありません: $MANIFEST"
[[ "$(jq -r '.schemaVersion' "$MANIFEST")" == "1" ]] || die "未対応の schemaVersion です"

if [[ "$MODE" == "list" ]]; then
    count="$(jq '.models | length' "$MANIFEST")"
    if [[ "$count" == "0" ]]; then
        echo "マニフェストに登録されたモデルはありません ($MANIFEST)"
        exit 0
    fi
    jq -r '.models[] | [.id, .backend, .format, .quantization, .license.identifier, .license.redistribution,
        "\((.files | map(.size) | add) / 1048576 | floor) MB"] | @tsv' "$MANIFEST" |
        column -t -s $'\t'
    exit 0
fi

[[ -n "$MODEL_ID" ]] || usage 64
[[ "$MODEL_ID" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]] || die "Model ID が不正です: $MODEL_ID"

MODEL_JSON="$(jq -c --arg id "$MODEL_ID" '[.models[] | select(.id == $id)] | if length == 1 then .[0] else empty end' "$MANIFEST")"
[[ -n "$MODEL_JSON" ]] || die "マニフェストに $MODEL_ID がない（または重複している）"

# --- マニフェストの検証（ModelManifest.validate() と同じ制約） ---
REVISION="$(jq -r '.source.revision' <<<"$MODEL_JSON")"
BASE_URL="$(jq -r '.source.downloadBaseURL' <<<"$MODEL_JSON")"
[[ "$REVISION" =~ ^[A-Za-z0-9]+$ ]] || die "revision はコミットハッシュで指定してください"
[[ "$BASE_URL" == https://* ]] || die "downloadBaseURL は HTTPS にしてください"
[[ "$BASE_URL" == *"$REVISION"* ]] || die "downloadBaseURL に revision が含まれていません"
LICENSE_DOC="$(jq -r '.license.documentPath' <<<"$MODEL_JSON")"
jq -e --arg p "$LICENSE_DOC" 'any(.files[]; .path == $p)' <<<"$MODEL_JSON" >/dev/null ||
    die "ライセンス文書 ($LICENSE_DOC) がファイル一覧に含まれていません"

FILES=()
while IFS=$'\t' read -r path sha size; do
    [[ -n "$path" && "$path" != /* && "$path" != *\\* ]] || die "不正なファイルパス: $path"
    IFS='/' read -r -a parts <<<"$path"
    for part in "${parts[@]}"; do
        [[ -n "$part" && "$part" != .* ]] || die "不正なファイルパス: $path"
    done
    [[ "$path" != */ ]] || die "不正なファイルパス: $path"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "SHA-256 が不正です: $path"
    [[ "$size" =~ ^[1-9][0-9]*$ ]] || die "サイズが不正です: $path"
    FILES+=("$path"$'\t'"$sha"$'\t'"$size")
done < <(jq -r '.files[] | [.path, .sha256, (.size | tostring)] | @tsv' <<<"$MODEL_JSON")
[[ ${#FILES[@]} -gt 0 ]] || die "ファイル一覧が空です"

# ファイル一覧をディレクトリに対して検証する（サイズ → SHA-256）
verify_files() {
    local dir="$1" entry path sha size actual
    for entry in "${FILES[@]}"; do
        IFS=$'\t' read -r path sha size <<<"$entry"
        [[ -f "$dir/$path" && ! -L "$dir/$path" ]] || { echo "missing: $path" >&2; return 1; }
        actual="$(stat -f %z "$dir/$path")"
        [[ "$actual" == "$size" ]] || { echo "size mismatch: $path ($actual != $size)" >&2; return 1; }
        actual="$(shasum -a 256 "$dir/$path" | awk '{print $1}')"
        [[ "$actual" == "$sha" ]] || { echo "SHA-256 mismatch: $path" >&2; return 1; }
        echo "  ok  $path"
    done
}

FINAL_DIR="$DEST_ROOT/$MODEL_ID"

if [[ "$MODE" == "verify" ]]; then
    [[ -f "$FINAL_DIR/$RECEIPT_NAME" ]] || die "$MODEL_ID はインストールされていません ($FINAL_DIR)"
    installed_rev="$(jq -r '.revision' "$FINAL_DIR/$RECEIPT_NAME")"
    [[ "$installed_rev" == "$REVISION" ]] || die "インストール済みの revision ($installed_rev) がマニフェストと異なります"
    verify_files "$FINAL_DIR" || die "検証に失敗しました: $MODEL_ID"
    echo "verified: $FINAL_DIR"
    exit 0
fi

# --- ダウンロード ---
STATUS="$(jq -r '.license.redistribution' <<<"$MODEL_JSON")"
if [[ "$STATUS" != "verified" ]]; then
    echo "note: $MODEL_ID の再配布可否は「${STATUS}」です。開発用途に限り取得し、製品ビルドには同梱しないでください。" >&2
fi

mkdir -p "$DEST_ROOT/.staging"
STAGING="$(mktemp -d "$DEST_ROOT/.staging/$MODEL_ID-XXXXXX")"
OLD_DIR=""
cleanup() {
    rm -rf "$STAGING"
    [[ -z "$OLD_DIR" ]] || rm -rf "$OLD_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "Downloading $MODEL_ID (revision $REVISION) -> $FINAL_DIR"
for entry in "${FILES[@]}"; do
    IFS=$'\t' read -r path sha size <<<"$entry"
    mkdir -p "$(dirname "$STAGING/$path")"
    echo "  get $path ($size bytes)"
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 --silent --show-error \
        --output "$STAGING/$path" "$BASE_URL/$path" || die "ダウンロードに失敗しました: $path"
done

verify_files "$STAGING" || die "検証に失敗しました。取得したファイルは破棄します"

jq -n --argjson model "$MODEL_JSON" --arg installedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion: 1, modelID: $model.id, revision: $model.source.revision,
      files: $model.files, installedAt: $installedAt}' > "$STAGING/$RECEIPT_NAME"

# 既存を退避してから同一ボリューム内の rename で配置する（検証済みのものだけが最終位置に置かれる）
if [[ -e "$FINAL_DIR" ]]; then
    OLD_DIR="$DEST_ROOT/.staging/$MODEL_ID-old-$$"
    mv "$FINAL_DIR" "$OLD_DIR"
fi
mv "$STAGING" "$FINAL_DIR"
echo "installed: $FINAL_DIR"
echo "license:   $FINAL_DIR/$LICENSE_DOC ($(jq -r '.license.identifier' <<<"$MODEL_JSON"))"
