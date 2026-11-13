//
//  SettingsView.swift
//  Kanato
//

import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var status: Status?
    @State private var isTesting = false
    /// 同梱のモデルマニフェスト（メタデータのみ）。読めない場合は nil
    @State private var manifest = try? ModelManifest.loadBundled()

    private enum Status {
        case success(String)
        case failure(String)
    }

    /// 接続テストに使う短文
    private static let testInput = "きょうはいいてんきです"

    var body: some View {
        Form {
            Section("推論バックエンド") {
                Picker("モード", selection: $settings.distributionMode) {
                    ForEach(DistributionMode.allCases, id: \.self) { mode in
                        Text(mode.isEnabled ? mode.displayName : "\(mode.displayName)（未有効化）")
                            .tag(mode)
                    }
                }
                switch settings.distributionMode {
                case .external:
                    EmptyView()
                case .download:
                    localModelPicker
                    Label("ローカル推論エンジンは未実装です。このモードでの変換はエラーになります。",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                case .embedded:
                    Label(InferenceBackendError.embeddedModeDisabled.errorDescription ?? "",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("LLM接続（External）") {
                Picker("API形式", selection: $settings.apiFormat) {
                    ForEach(ExternalAPIFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                TextField("API Base URL", text: $settings.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    .autocorrectionDisabled()
                if settings.apiFormat == .zenz {
                    TextField("Model ID（任意）", text: $settings.model, prompt: Text("例: zenz-v2.5-medium"))
                        .autocorrectionDisabled()
                    Text("zenz は /completions で呼び出します（例: llama-server の http://127.0.0.1:8801/v1）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Model ID", text: $settings.model, prompt: Text("例: qwen2.5-7b-instruct"))
                        .autocorrectionDisabled()
                }
                SecureField("API Key（任意）", text: $settings.apiKey)
                Stepper(value: $settings.timeout, in: AppSettings.timeoutRange, step: 1) {
                    LabeledContent("タイムアウト", value: "\(Int(settings.timeout)) 秒")
                }
                Toggle("temperature = 0 を送信する", isOn: $settings.sendTemperature)
                Toggle("ローカルネットワーク（.local / プライベートIP）へのHTTPを許可", isOn: $settings.allowLocalNetworkHTTP)
            }

            Section {
                if AppSettings.isRemote(baseURL: settings.baseURL) {
                    Label("この接続先はlocalhostではありません。変換時、選択した文字列がこのサーバーへ送信されます。",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("選択した文字列はこのMac上のLLMサーバーへのみ送信されます。", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
                Text("APIキーはKeychainに保存されます。入力・変換テキストは保存・ログ記録されません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("接続テスト", action: runConnectionTest)
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("保存", action: save)
                        .keyboardShortcut("s")
                }
                if let status {
                    switch status {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
    }

    @ViewBuilder
    private var localModelPicker: some View {
        let models = manifest?.models ?? []
        if models.isEmpty {
            Text("モデルマニフェストに登録されたモデルはありません")
                .foregroundStyle(.secondary)
        } else {
            Picker("モデル", selection: $settings.localModelID) {
                Text("未選択").tag("")
                ForEach(models) { model in
                    Text("\(model.name)（\(model.backend.displayName) / ライセンス\(model.license.redistribution.displayName)）")
                        .tag(model.id)
                }
            }
        }
    }

    private func save() {
        if settings.save() {
            status = .success("保存しました")
        } else {
            status = .failure("APIキーをKeychainに保存できませんでした")
        }
    }

    /// 画面上の (未保存を含む) 設定で実際に小さな変換リクエストを送る
    private func runConnectionTest() {
        let backend = InferenceBackendFactory().makeBackend(
            selection: settings.backendSelection,
            configuration: settings.configuration
        )
        isTesting = true
        status = nil
        Task {
            do {
                let result = try await backend.convert(Self.testInput)
                status = .success("成功: \(Self.testInput) → \(result)")
            } catch {
                status = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }
}

#Preview {
    SettingsView()
}
