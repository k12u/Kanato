# Kanato

ひらがなで入力した日本語文章を、macOS の「サービス」から LLM で一括かな漢字変換するアプリ（MVP）。

```
きょうのかいぎでけっていしたしようをらいしゅうまでにじっそうする
→ 今日の会議で決定した仕様を来週までに実装する
```

## 使い方

1. 任意のアプリでひらがな文章を入力し、範囲を選択する
2. メニュー「アプリ名 > サービス > **Kanatoで変換**」を実行する
3. 選択範囲が変換結果で置き換わる（失敗時は何も変更されず、ビープ音が鳴る）

キーボードショートカットは「システム設定 > キーボード > キーボードショートカット > サービス > テキスト」で割り当てられます。

## セットアップ

1. OpenAI 互換 API を持つ LLM サーバーを用意する（例: LM Studio を `http://localhost:1234/v1` で起動）
2. Xcode で `Kanato` スキームをビルドして起動する
3. 設定ウィンドウで **Model ID** を入力し「接続テスト」→「保存」
4. **「システム設定 > キーボード > キーボードショートカット… > サービス > テキスト」で「Kanatoで変換」にチェックを入れる**
   - 新しく追加されたサードパーティのサービスは既定で無効になっており、チェックを入れるまでサービスメニューに表示されません（2026-11-13、macOS 27 で確認）
5. それでもサービスメニューに出ない場合:
   - アプリを一度起動する（起動時に `NSUpdateDynamicServices()` を呼んでいます）
   - `/System/Library/CoreServices/pbs -update` を実行し、対象アプリ（TextEdit など）を再起動する
   - `pbs -dump` の `NSBundlePath` が、存在する Kanato.app を指しているか確認する。同じバンドル ID の Kanato.app が複数ビルドされていると、削除済みのコピーが選ばれることがあります。その場合は `lsregister -u <古い Kanato.app のパス>` で登録を外してから `pbs -update` を実行してください（`lsregister` は `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`）

### 設定項目

| 項目 | 既定値 | 保存先 |
|---|---|---|
| 推論バックエンドのモード | External | UserDefaults |
| API 形式（Chat Completions / zenz） | Chat Completions | UserDefaults |
| API Base URL（`/v1` まで） | `http://localhost:1234/v1` | UserDefaults |
| Model ID | なし（必須） | UserDefaults |
| API Key（任意） | なし | Keychain |
| タイムアウト | 8 秒（1〜12 秒） | UserDefaults |
| temperature = 0 を送信 | オン（非対応モデル向けにオフにできる） | UserDefaults |
| ローカルネットワークへの HTTP を許可 | オフ | UserDefaults |

## 開発用 Mock LLM Server（DevServer）

`DevServer/` は **開発・テスト専用** の OpenAI 互換 Mock LLM Server です（Swift Package / Hummingbird 2.x）。本物の LLM は実行せず、固定の変換結果を返します。

目的:

- macOS Service から HTTP リクエストが届き、選択範囲が置換されることの確認
- HTTP エラー・不正レスポンス・遅延（タイムアウト）の再現
- 実 LLM を起動せずにアプリの開発・テストを行う

DevServer は Kanato ターゲットから一切依存されていないため、**リリース用の `Kanato.app` には含まれません**（Release ビルドの `.app` は `Contents/MacOS/Kanato` のみで、Hummingbird / SwiftNIO はリンクされていないことを確認済み）。

### Xcode からの起動

1. `Kanato.xcworkspace` を開く（`Kanato.xcodeproj` と `DevServer` パッケージの両方を含む）
2. スキーム **DevServer**、実行先 **My Mac** を選んで Run
3. コンソールに待ち受けアドレス・ポート・Mock Mode が表示される

```
KanaFilter DevServer (development only)
  Listen:  127.0.0.1:8765
  BaseURL: http://127.0.0.1:8765/v1
  Model:   kanafilter-mock
  Mode:    normal
  Delay:   0 ms
```

Mock Mode・遅延・ポートは「Edit Scheme… > Run > Arguments > Environment Variables」で変更します（共有スキームに既定値を設定済み）。`DevServer/Package.swift` を単独で Xcode で開いても同じスキームで実行できます。

### コマンドラインからの起動

```bash
cd DevServer
swift run DevServer
# 障害モード・遅延・ポートを指定
KANAFILTER_MOCK_MODE=http500 KANAFILTER_MOCK_DELAY_MS=2000 KANAFILTER_MOCK_PORT=8765 swift run DevServer
```

テスト: `xcodebuild -scheme DevServer -destination platform=macOS test`（`DevServer/` で実行）または Xcode で DevServer スキームを Test。

### エンドポイント

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/health` | `{"status":"ok","service":"KanaFilter DevServer"}` |
| GET | `/v1/models` | モデル一覧（`kanafilter-mock` のみ） |
| POST | `/v1/chat/completions` | 最後の `role: user` の `content` を固定マッピングで変換して返す |

`/v1/chat/completions` は以下を HTTP 400（OpenAI 形式の `error` オブジェクト）で拒否します: 不正な JSON、`stream: true`、`kanafilter-mock` 以外のモデル、空の `messages`、`user` メッセージなし。

固定マッピング（前後の空白を除いて照合。未登録の入力はそのまま返す）:

| 入力 | 出力 |
|---|---|
| きょうはいいてんきです | 今日はいい天気です |
| このしようはまだかくていしていない | この仕様はまだ確定していない |
| らいしゅうのかいぎでかくにんする | 来週の会議で確認する |
| ぱいそんでじっそうする | Pythonで実装する |
| てすと | テスト |

### Mock Mode と環境変数

| 環境変数 | 既定値 | 内容 |
|---|---|---|
| `KANAFILTER_MOCK_MODE` | `normal` | 下表のいずれか |
| `KANAFILTER_MOCK_DELAY_MS` | `0` | `/v1/chat/completions` の応答前に待つミリ秒（モードと独立） |
| `KANAFILTER_MOCK_PORT` | `8765` | 待ち受けポート |
| `KANAFILTER_MOCK_HOST` | `127.0.0.1` | 待ち受けアドレス。認証がないため、明示的に必要な場合以外は変更しない |

| モード | `/v1/chat/completions` の応答 |
|---|---|
| `normal` | 200、固定マッピングで変換 |
| `http500` | 500、`{"error":{...,"type":"server_error"}}` |
| `empty_choices` | 200、`"choices": []` |
| `empty_content` | 200、`"content": ""` |
| `invalid_json` | 200（`Content-Type: application/json`）、途中で切れた JSON |

接続失敗は DevServer を停止して再現します。`/health` と `/v1/models` はモードの影響を受けません。不正な環境変数を指定すると終了コード 64 で起動しません。

### curl による動作確認

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/v1/models
curl http://127.0.0.1:8765/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"kanafilter-mock","messages":[{"role":"system","content":"かな漢字変換を実行してください"},{"role":"user","content":"きょうはいいてんきです"}],"temperature":0,"stream":false}'
# → {"choices":[{"finish_reason":"stop","index":0,"message":{"content":"今日はいい天気です","role":"assistant"}}],...}
```

### Kanato の接続設定

| 項目 | Mock Server | 実 LLM サーバー（例: LM Studio） |
|---|---|---|
| API Base URL | `http://127.0.0.1:8765/v1` | `http://127.0.0.1:1234/v1`（推論エンジンに合わせる） |
| Model ID | `kanafilter-mock` | 推論エンジンで設定したモデル ID |
| API Key | なし | 必要な場合のみ |

アプリには Mock Server 固有の処理はなく、上の 2 項目を切り替えるだけで接続先が変わります。`127.0.0.1` への HTTP は既存の ATS 設定（`NSAllowsLocalNetworking`）とアプリ側の loopback 判定の範囲内なので、ATS・Sandbox・署名の設定は変更していません。Mock Server は変換品質の評価には使いません。

保存済み設定を変えずに一時的に Mock Server へつなぐ場合は、起動引数で上書きできます（UserDefaults の引数ドメイン）:

```bash
open -n Kanato.app --args -baseURL http://127.0.0.1:8765/v1 -model kanafilter-mock
```

### 確認手順

1. DevServer スキームを Run
2. `curl http://127.0.0.1:8765/health` で起動を確認
3. Kanato スキームでアプリを起動
4. 設定画面に上記の値を入力して「接続テスト」→「保存」
5. TextEdit で `きょうはいいてんきです` を選択し「サービス > Kanatoで変換」（メニューに出ない場合は「セットアップ」の手順 4 で、サービスが有効になっているか確認）

両プロセスを Xcode から同時に自動起動する仕組みは用意していません（それぞれのスキームで Run してください）。

## ローカルモデル（オンデバイス推論）

アプリ内の llama.cpp で、かな漢字変換専用モデル zenz をこの Mac 上で実行できます（Download モード）。外部 API（External モード）も引き続き使えます。詳細は [docs/local-models.md](docs/local-models.md) を参照してください。

| 配布モード | 状態 |
|---|---|
| External（外部 API・既定） | 動作する。API 形式は Chat Completions（汎用 LLM）/ zenz v2 / zenz v3 を選択 |
| Download（初回実行時に取得） | 動作する（zenz-v3.2-small, 70 MB）。設定画面からダウンロードし、アプリ内の llama.cpp で変換する。モデルは公式の Hugging Face から直接取得し、アプリは再配布しない |
| Embedded（同梱） | 無効。モデル選定とライセンス確認後に有効化する |

- モデルの管理情報: `Kanato/LocalModels/model-manifest.json`（Model ID・配布元・revision・ファイルと SHA-256・ライセンスと再配布可否の確認状態・バックエンド・形式・量子化・必要メモリ）
- 重みファイルは Git にコミットせず、アプリにも同梱しません（`.gitignore` で除外）
- 開発用の取得: `scripts/download-model.sh --list` / `scripts/download-model.sh <MODEL_ID>`（保存先 `.models/`、ハッシュ検証つき）
- 登録済み: zenz-v3.2-small（アプリ内推論用。ダウンロード利用のライセンス確認済み）/ zenz-v2.5-medium・Qwen3-1.7B (Q8_0)・Qwen3-4B (Q4_K_M)（開発・評価用、未確認）。評価では zenz 系が最良（19 文中 17 文一致）
- アプリ内で試す: 設定の「推論バックエンド」でモード「Download」、モデル「zenz-v3.2-small」を選び「ダウンロード」→「保存」
- 外部サーバーで試す: `scripts/convert-model-gguf.sh zenz-v2.5-medium` → `scripts/serve-model.sh zenz-v2.5-medium --port 8801` → 設定で API 形式「zenz v2」、API Base URL `http://127.0.0.1:8801/v1`
- 混入チェック: `scripts/check-model-artifacts.sh [Kanato.app]`

## 構成

```
Kanato/
├── KanatoApp.swift                 # エントリーポイント・設定ウィンドウ
├── AppDelegate.swift               # servicesProvider の設定と強参照保持
├── Info.plist                      # NSServices / ATS（自動生成 Info.plist にマージされる）
├── Services/KanaServiceProvider.swift   # pasteboard 入出力と同期ブリッジ
├── Conversion/                     # ConversionService / Prompt / Validator / Error
├── Networking/OpenAICompatibleClient.swift
├── Inference/                      # InferenceBackend / ExternalAPIBackend / ZenzBackend / LocalModelBackend / LlamaCppEngine / Factory
├── LocalModels/                    # ModelManifest / ModelManager / model-manifest.json（重みは含まない）
└── Settings/                       # AppSettings / SettingsView / APIKeyStore
KanatoTests/                        # Swift Testing によるユニットテスト
DevServer/                          # 開発用 Mock LLM Server（独立した Swift Package、アプリには非同梱）
├── Package.swift
├── Sources/DevServer/              # main / MockLLMServer / ChatCompletionModels / MockConversionEngine
└── Tests/DevServerTests/
Kanato.xcworkspace                  # Kanato.xcodeproj + DevServer をまとめて開くワークスペース
scripts/                            # download / convert / serve / eval / perform-service / check-model-artifacts
docs/local-models.md                # ローカルモデル管理・推論基盤の設計
Packages/LlamaCpp/                  # llama.cpp 公式 XCFramework（URL・チェックサム固定）と Swift ラッパー
.models/                            # 開発用モデルの保存先（Git 管理外）
```

変換ロジック（`Conversion/`, `Networking/`）は AppKit / SwiftUI に依存せず、`nonisolated` かつ `Sendable` にしてあるため、後から Swift Package へ切り出せます。

## 主要な実装判断

- **同期サービスと async の橋渡し**: サービスメソッドはメインスレッドで同期的に呼ばれるため、変換は `Task.detached` で実行し、メインスレッドは `DispatchSemaphore` で上限付きで待ちます（`BlockingBridge`）。変換処理は MainActor に一切依存しないためデッドロックしません。
- **タイムアウトの階層**: HTTP タイムアウト（既定 8 秒、最大 12 秒）< ブリッジの待ち上限（HTTP + 1.5 秒、最大 13 秒）< `NSTimeout`（15 秒）。
- **元テキストの保護**: pasteboard は成功時にしか書き換えません。タイムアウト後に届いた遅延レスポンスはブリッジ内の箱に入るだけで、pasteboard には反映されません。失敗時は `error` ポインタにメッセージを設定します。
- **出力検証**: 空・最大長超過（入力長 × 2 + 32）・入力にないコードフェンス / JSON / 説明文の書き出し / 全体を囲む引用符はエラー。LLM が付けた前後の空白は除去し、原文の前後空白（末尾改行など）だけを復元します。推論モデルの先頭 `<think>…</think>` は除去します。
- **入力上限**: 4000 文字。
- **ATS / Sandbox**: App Sandbox 有効、Outgoing Connections のみ許可。ATS は `NSAllowsLocalNetworking` のみで、任意ロードの全面許可はしていません。アプリ側でも HTTP は localhost（設定でオプトインした場合は `.local` とプライベート IPv4 も）に限定し、それ以外は HTTPS 必須です。
- **プライバシー**: 入力・変換本文・API キーはログ出力・保存しません（ログは所要時間とエラー種別のみ）。localhost 以外の接続先を設定すると、設定画面に送信される旨の警告を表示します。
- **常駐**: ウィンドウを閉じても終了しません（ウォームスタートでサービスを受けるため）。終了は ⌘Q。

## テスト

### Unit Tests（`KanatoTests`）

LLM クライアントはプロトコル `ChatCompletionClient` 経由でモックを注入し、HTTP 層は `URLProtocol` スタブで検証しています。

正常変換 / 空入力 / 空レスポンス / HTTP 400・401・500 / 接続失敗 / タイムアウト / 不正 JSON / `choices` 空 / `content` null / コードフェンス / 複数行 / 英数字混在 / URL・コード片 / baseURL 正規化 / HTTP 制限 など。

`KanaServiceProviderTests` では、DevServer の各 Mock Mode が返す実レスポンス（http500 / empty_choices / empty_content / invalid_json）とサーバー停止・タイムアウトを再生し、サービス失敗時に pasteboard の原文が保持されることを確認しています。

`ModelManifestTests` / `ModelManagerTests` / `InferenceBackendTests` では、マニフェストの検証（パス逸脱・未固定 revision・ライセンス文書の欠落など）、ダウンロード後の SHA-256 検証、失敗時のクリーンアップと既存インストールの保持、改ざん検出、ライセンス未確認モデルの取得拒否（Release 方針）、無効な Embedded が明確なエラーになることを確認しています。

`ZenzBackendTests` では、zenz 形式のプロンプト（カタカナ化・左文脈）、行ごとの変換と空白の保持、ASCII の素通し、長い行の分割、制御タグを含む出力の拒否を確認しています。

`LocalModelBackendTests` では、ローカル推論でのプロンプト形式（zenz v2 / v3）、読み込み済みエンジンの再利用と差し替え、未対応の形式（チャット・safetensors）・読み込み失敗が明確なエラーになることを確認しています。

2026-11-14 時点: **117 tests passed**（UI テンプレート 2 件含む）

### Unit Tests（`DevServerTests`）

`/health`・`/v1/models`・Chat Completions の正常系、固定マッピング全件、未登録テキスト、`messages` 空・`user` なし・不明モデル・`stream: true`・不正リクエストの 400、遅延、各障害モード、環境変数の解釈、実ソケットでの疎通。

2026-11-13 時点: **26 tests（37 ケース）passed**

### DevServer を使ったサービス経路の検証（2026-11-13、開発機）

Debug ビルドの Kanato を起動引数で DevServer に向け、`NSPerformService("Kanatoで変換", …)` で実際のサービス経路を呼び出して確認:

| DevServer の状態 | 結果 |
|---|---|
| `normal`・固定マッピング 5 件 | すべて置換（各 0.01〜0.03 秒） |
| `normal`・未登録テキスト | 入力のまま返る |
| `normal`・前後に空白／改行 (`"  てすと\n"`) | `"  テスト\n"`（原文の前後空白を維持） |
| `http500` / `empty_choices` / `empty_content` / `invalid_json` | 元テキスト保持 |
| 遅延 1000 ms | 置換（1.05 秒） |
| 遅延 10000 ms（既定タイムアウト 8 秒超） | 8.02 秒でタイムアウト、元テキスト保持 |
| DevServer 停止 | 元テキスト保持、Kanato は動作継続 |

### サービス経路の検証（2026-11-13、開発機）

`NSPerformService("Kanatoで変換", …)` から実際のサービス経路を呼び、モック OpenAI 互換サーバーで確認:

| ケース | 結果 |
|---|---|
| Step 1 固定文字列（`てすと` → `テスト成功`） | OK |
| 正常応答（前後に改行付き） | 置換、余分な空白なし |
| LLM サーバー未起動 | 元テキスト保持、エラー返却 |
| コードフェンス付き応答 | 元テキスト保持 |
| 不正 JSON | 元テキスト保持 |
| 20 秒無応答 | 8.09 秒でタイムアウト、元テキスト保持 |

### 性能（サービス側オーバーヘッド、モックサーバー＝推論時間ほぼ 0）

| 指標 | 実測 |
|---|---|
| コールドスタート（アプリ未起動 → 結果返却） | 0.45〜0.67 秒 |
| ウォームスタート | 0.010〜0.012 秒 |

実 LLM の推論時間・HTTP 所要時間は Console.app で subsystem `org.k12u.Kanato` のログ（`HTTP request finished in …` / `Service succeeded in …` / cold start の起動からの経過）で確認できます。実 LLM での計測は未実施です。

### アプリ別対応状況（Integration）

2026-11-13 に TextEdit で、DevServer（`normal`）を相手にメニュー表示から置換までを確認しました。2026-11-14 に VS Code・Claude・Codex・Slack でも変換できることを確認しました。ターミナルでは選択範囲が置き換わらず、変換結果が後ろに追加されます（既知の制約を参照）。空欄の項目とほかのアプリは未確認です（実機での手動確認が必要）。

| アプリ | メニュー表示 | 取得 | 置換 | 範囲外不変 | Undo | 失敗時保持 |
|---|---|---|---|---|---|---|
| TextEdit | OK | OK | OK | | | |
| メモ | | | | | | |
| Safari 入力欄 | | | | | | |
| Chrome 入力欄 | | | | | | |
| VS Code | OK | OK | OK | | | |
| Claude | OK | OK | OK | | | |
| Codex | OK | OK | OK | | | |
| Slack | OK | OK | OK | | | |
| ターミナル | OK | OK | NG（選択範囲が残り、結果が追加される） | | | |

## 既知の制約

- 変換中（最大約 13 秒）は呼び出し元アプリの UI がブロックされます（macOS Services の同期仕様による MVP の制約）。
- サービスのエラーメッセージを表示するかは呼び出し元アプリ次第です。Kanato 側では失敗時にビープ音を鳴らします。
- Services に対応していないアプリでは使えません。MVP では Accessibility API による代替は行いません。
- Kanato は選択したテキストを変換結果で置き換えるサービスのため、選択範囲の置き換えに対応していないアプリ（例: ターミナル）では、選択した文字が消えずに変換結果が入力として追加されます（例: `にほんごへんかん` → `にほんごへんかん日本語変換`）。
- 署名なし（ad-hoc）でビルドし直すと、Keychain の API キーへのアクセス確認ダイアログが出ることがあります。
- 一般配布用の Developer ID 署名・公証・DMG 作成は未対応（MVP 後の工程）。

## ライセンス

- Kanato のソースコード: [MIT License](LICENSE)（Copyright (c) 2026 k12u）
- 同梱ソフトウェア: llama.cpp / ggml（MIT License）。表示は [Kanato/Legal/ThirdPartyNotices.txt](Kanato/Legal/ThirdPartyNotices.txt) にまとめ、アプリにも同梱して設定画面の「ライセンス表示」から確認できます
- モデル: リポジトリにもアプリにも含みません。ユーザーが配布元から直接ダウンロードし、各モデルのライセンスに従います。アプリ内推論で使う zenz-v3.2-small は CC BY-SA 4.0（© Keita Miwa）で、帰属表示を設定画面に掲載しています。方針の詳細は [docs/local-models.md](docs/local-models.md#モデルのライセンスと配布方針) を参照
