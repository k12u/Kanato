# ローカルモデル管理・推論基盤

将来のオンデバイス推論に向けた、モデル管理と推論バックエンドの構成。**2026-11-13 時点では、ローカル推論エンジンは未実装で、モデルも未選定**です。動作するのは External（外部 API）だけです。

## 方針

| 項目 | 方針 |
|---|---|
| 管理情報 | `Kanato/LocalModels/model-manifest.json` に一元化して Git 管理する（アプリにも同梱。重みは含まない） |
| 重みファイル | Git にコミットしない（`.gitignore`）。Xcode の同期フォルダ（`Kanato/` など）に置かない |
| 開発用モデル | `scripts/download-model.sh` で `<repo>/.models/<MODEL_ID>/` に取得する（Git 管理外） |
| アプリでの保存先 | `Application Support/Kanato/Models/<MODEL_ID>/`（Sandbox 下ではコンテナ内） |
| 未確認ライセンス | 製品ビルドへ同梱しない。Release ビルドの `ModelManager` は `verified` 以外を取得しない |
| Mock Server との区別 | DevServer は External モードの接続先の 1 つにすぎない。ローカル推論とは別物 |

## Model Manifest

`schemaVersion: 1`。読み込み時に `ModelManifest.validate()`（Swift）と `download-model.sh`（jq）の両方で同じ制約を検証します。

```json
{
  "schemaVersion": 1,
  "models": [
    {
      "id": "example-model-q4",
      "name": "Example Model (Q4_K_M)",
      "source": {
        "repositoryURL": "https://huggingface.co/<org>/<repo>",
        "revision": "<40 桁のコミットハッシュ>",
        "downloadBaseURL": "https://huggingface.co/<org>/<repo>/resolve/<40 桁のコミットハッシュ>"
      },
      "files": [
        { "path": "model-q4_k_m.gguf", "sha256": "<小文字 16 進 64 桁>", "size": 1234567890 },
        { "path": "LICENSE", "sha256": "<...>", "size": 11357 }
      ],
      "license": {
        "identifier": "Apache-2.0",
        "documentPath": "LICENSE",
        "redistribution": "unverified",
        "notes": "確認者・確認日・根拠"
      },
      "backend": "llama.cpp",
      "format": "gguf",
      "quantization": "Q4_K_M",
      "estimatedMemoryMB": 2048
    }
  ]
}
```

| フィールド | 内容・制約 |
|---|---|
| `id` | 英数字と `._-`（先頭 `.` 不可）。保存先ディレクトリ名になる |
| `source.revision` | コミットハッシュ（英数字のみ）。ブランチ名は使わない |
| `source.downloadBaseURL` | HTTPS で、`revision` を含むこと。各ファイルは `downloadBaseURL/path` から取得する |
| `files[].path` | 相対パス。`..`・絶対パス・隠しファイルは不可 |
| `files[].sha256` / `size` | 取得後に必ず照合する。一致しなければ破棄する |
| `license.documentPath` | `files` に含めること（モデルと一緒に取得・検証・保持する） |
| `license.redistribution` | `unverified`（未確認）/ `in-review`（確認中）/ `verified`（確認済み） |
| `backend` | `mlx` / `llama.cpp` |
| `format` | `mlx` / `gguf` / `safetensors`（Hugging Face Transformers 形式。llama.cpp で使うには GGUF へ変換する） |
| `estimatedMemoryMB` | 推論時のおおよその必要メモリ |

モデルを追加するときは、ファイルを取得してから `shasum -a 256` と `stat -f %z` で値を記入し、`scripts/download-model.sh <id>` で取得・検証できることを確認します。

## インストールの原子性

`ModelManager`（アプリ）と `download-model.sh`（開発用）は同じレイアウトで保存します。

1. `<root>/.staging/<id>-<ランダム>/` に全ファイルを取得
2. 全ファイルのサイズと SHA-256 をマニフェストと照合
3. インストール記録 `.kanato-install.json`（Model ID・revision・ファイル一覧・日時）を書く
4. 同一ボリューム内の rename で `<root>/<id>/` に配置（既存は検証成功時にのみ置き換える）

途中で失敗した場合は一時ディレクトリを削除します。インストール記録のないディレクトリや、revision・ファイル一覧がマニフェストと異なるものは使用可能なモデルとして扱いません。

`ModelManager` の API: `installedModels()` / `installState(of:)` / `missingFiles(of:)` / `verify(_:)` / `download(_:progress:)` / `delete(modelID:)` / `storageUsage()` / `cleanUpStaging()`。

## 推論バックエンド

```swift
protocol InferenceBackend: Sendable {
    func convert(_ text: String) async throws -> String
}
```

| 型 | 内容 |
|---|---|
| `ExternalAPIBackend` | 既存の `OpenAICompatibleClient` + `ConversionService`（プロンプト・入出力検証） |
| `LocalModelBackend` | 検証済みモデルディレクトリと `LocalInferenceEngine` を組み合わせる。エンジン未登録なら `localInferenceNotImplemented` |
| `UnavailableBackend` | 選択された構成が使えない理由をそのままエラーにする |
| `InferenceBackendFactory` | 設定（配布モード・Model ID）からバックエンドを生成する |

`LocalInferenceEngine` は `ChatCompletionClient` を継承するため、ローカル推論でも外部 API と同じプロンプト・出力検証を通ります。エンジンを実装したら `LocalInferenceEngines.engineTypes` に登録します。

選択された構成が使えない場合（エンジン未実装・モデル未取得・Embedded 無効など）は、**外部 API へ暗黙にフォールバックせず**、サービスは元のテキストを保持したままエラーを返します。

## 配布モード

| モード | 状態 | 内容 |
|---|---|---|
| External | **動作する（既定）** | ユーザーが設定した OpenAI 互換 API（LM Studio・DevServer・llama-server など）。API 形式は Chat Completions（汎用 LLM）と zenz を選べる |
| Download | 管理基盤のみ | マニフェストのモデルを Application Support へ取得・検証する。推論エンジン未実装のため変換はエラー |
| Embedded | 無効 | モデル選定とライセンス確認（`verified`）後に有効化する。現在は常にエラー |

設定画面の「推論バックエンド」、または起動引数（`-distributionMode download -localModelID <id>`）で切り替えます。

## 配布物への混入防止

```bash
scripts/check-model-artifacts.sh                       # Git 管理下・同期フォルダを検査
scripts/check-model-artifacts.sh path/to/Kanato.app    # ビルド済みアプリも検査
```

- Git 管理下の重みファイル、`.models/` 配下のファイル → NG
- `Kanato/` などの同期フォルダ内の重みファイル（ビルドで自動的に同梱される）→ NG
- アプリ内の重みファイルは、`Contents/Resources/Models/<id>/` 配下かつマニフェストで `verified` のモデルのみ許可。それ以外 → NG

リリース前（Archive 後）に実行してください。ビルドフェーズへの組み込みは Embedded を有効化するときに行います。

## 推論エンジン候補の評価（未決定）

| 観点 | MLX Swift | llama.cpp |
|---|---|---|
| 組み込み方法 | Swift Package（`mlx-swift` と LLM 用ライブラリ） | C/C++ ライブラリ。XCFramework または Swift Package 経由 |
| モデル形式 | MLX 形式（safetensors + config / tokenizer、複数ファイル） | GGUF（単一ファイル） |
| 量子化 | 4bit / 8bit など | Q4_K_M・Q5_K_M・Q8_0 など選択肢が多い |
| 対応 CPU | Apple Silicon のみ（Metal） | Apple Silicon（Metal）と Intel |
| API | Swift ネイティブ。async/await と統合しやすい | C API を Swift でラップする必要がある |
| 配布物 | Metal シェーダー（metallib）の同梱が必要 | ライブラリと Metal シェーダーの同梱が必要 |
| モデルの入手性 | Hugging Face の mlx-community などに変換済みモデル | GGUF 変換済みモデルが広く流通 |

決定前に確認すること:

- 候補モデルでのかな漢字変換の品質（DevServer ではなく実モデルで評価する）
- 4000 文字入力時の初回ロード時間・推論時間（Services の 13 秒上限に収まるか）
- 必要メモリと、常駐アプリとしてのメモリ保持方針（ロード済みエンジンのキャッシュ・解放）
- App Sandbox・Hardened Runtime・公証での動作
- エンジン本体とモデルそれぞれのライセンス

## 開発用スクリプト

| スクリプト | 内容 |
|---|---|
| `scripts/download-model.sh <id>` | マニフェストのモデルを `.models/<id>/` に取得・検証する（`--list` / `--verify`） |
| `scripts/convert-model-gguf.sh <id>` | safetensors 形式を `.models/derived/<id>-f16.gguf` に変換する。インストール済み llama-server と同じコミットの変換スクリプトを `.models/.tools/` に用意する（uv が必要） |
| `scripts/serve-model.sh <id> [--port N]` | llama-server を 127.0.0.1 で起動し、Kanato に入力する設定値を表示する |
| `scripts/eval-conversion.py --target 名前=形式:URL ...` | 起動中のサーバーを `scripts/eval-cases.json` で評価する（`python3 -I` で実行） |
| `scripts/perform-service.swift` | 起動中の Kanato を実際のサービス経路（`NSPerformService`）で呼び出す |
| `scripts/check-model-artifacts.sh [Kanato.app]` | 重みファイルの混入を検査する |

zenz を Kanato で試す手順:

```bash
scripts/download-model.sh zenz-v2.5-medium
scripts/convert-model-gguf.sh zenz-v2.5-medium
scripts/serve-model.sh zenz-v2.5-medium --port 8801
# Kanato の設定: モード External / API形式 zenz / API Base URL http://127.0.0.1:8801/v1
```

## zenz 形式（ZenzBackend）

- `/v1/completions` に `U+EE00 + カタカナ入力 [+ U+EE02 + 左文脈] + U+EE01` を送り、EOS までの生成を変換結果とする（AzooKeyKanaKanjiConverter の `ZenzPromptBuilder` の v2 形式と同じ。左文脈は最大 40 文字）
- 改行ごとに変換し、各行の前後空白・空行は原文のまま残す。長い行は 200 文字以下に文末 → 読点の順で分割する
- **英字を含む ASCII の並び（`Apple`・`iPhone 17`・`Apple Developer Documentation` など）はモデルに渡さずそのまま残す。** zenz はかなの読みを前提に学習されており、ASCII を含めると出力が崩れる（例: `Appleも、…` をそのまま渡すと「も、アプリサイズのさめ、もでるるごにに…」、`Apple Developer Documentation` は `sleDeveloperDocumentations`）。英字を含まない ASCII（`3` や `-`）はかなと一緒に渡す（「ごご3じ」→「午後3時」）
- 分割した後続のかなには、同じ行の変換済みテキストを左文脈として渡す。文脈がないと、助詞で始まる長い文の先頭が欠けることがある（「も、アプリ…」→「プリ…」）
- 出力検証は `ConversionValidator` を使うが、説明文の書き出し判定は無効（「以下の通り」などを誤検出するため）。出力に制御タグ（U+EE00〜U+EEFF）が含まれていたらエラー
- 性能: ASCII だけの行はモデルを呼ばないため速い（1 行あたり約 130〜160 ms の生成を省略）。ASCII を挟む行は呼び出し回数が増えるが、1 回あたり数十 ms で、実測は 2 行の例文で 0.30 秒（サービス経由）

## 評価結果（2026-11-13、開発機・llama-server 経由）

マニフェスト登録済みの 3 モデルを `llama-server`（Homebrew llama.cpp, build 11669 / commit 620d2225c）で起動し、16 文（同音異義語・カタカナ語・数字・改行・約 90 文字の段落を含む）で比較した。Qwen3 は思考モードを無効化（`--reasoning off`）し、Kanato の `ConversionPrompt.literal` を system プロンプトに使用した。

| モデル | 完全一致 | 中央値 | 最大 | 備考 |
|---|---|---|---|---|
| zenz-v2.5-medium（f16 GGUF） | **14/16** | 70 ms | 244 ms | 誤りは「きしゃのきしゃは…」「いしにいしを」の同音異義語のみ。ASCII 混じりの 3 文を追加した 19 文では 17/19（ASCII 素通し後） |
| Qwen3-1.7B Q8_0 | 0/16（few-shot 1/16） | 144 ms | 553 ms | ほぼ入力をそのまま返す。few-shot では意味の改変あり |
| Qwen3-4B Q4_K_M | 0/16（few-shot 2/16） | 303 ms | 1363 ms | 部分的な変換・誤変換（「変身」「医者の医者は…」）、意味の改変あり |

補足:

- zenz はチャットモデルではないため Chat Completions は使えない（API 形式「zenz」を使う）
- GGUF への変換時、`convert_hf_to_gguf.py` が前処理（pre-tokenizer）を判定できないため `gpt-2` を指定した（`convert-model-gguf.sh` が zenz-* に自動適用）。HF tokenizer とトークン列が一致すること、スクリプトでの変換結果が手動変換と同一ハッシュになることを確認済み
- 2026-11-14 に Kanato の Debug ビルドを `-apiFormat zenz -baseURL http://127.0.0.1:8801/v1` で起動し、`perform-service` でサービス経路の変換を確認（ASCII 混じりの例文 0.30 秒、通常文 0.11〜0.15 秒）
