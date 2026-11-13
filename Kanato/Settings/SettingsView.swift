//
//  SettingsView.swift
//  Kanato
//

import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var status: Status?
    @State private var isTesting = false

    private enum Status {
        case success(String)
        case failure(String)
    }

    /// 接続テストに使う短文
    private static let testInput = "きょうはいいてんきです"

    var body: some View {
        Form {
            Section("LLM接続") {
                TextField("API Base URL", text: $settings.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    .autocorrectionDisabled()
                TextField("Model ID", text: $settings.model, prompt: Text("例: qwen2.5-7b-instruct"))
                    .autocorrectionDisabled()
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

    private func save() {
        if settings.save() {
            status = .success("保存しました")
        } else {
            status = .failure("APIキーをKeychainに保存できませんでした")
        }
    }

    /// 画面上の (未保存を含む) 設定で実際に小さな変換リクエストを送る
    private func runConnectionTest() {
        let service = ConversionService(client: OpenAICompatibleClient(configuration: settings.configuration))
        isTesting = true
        status = nil
        Task {
            do {
                let result = try await service.convert(text: Self.testInput)
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
