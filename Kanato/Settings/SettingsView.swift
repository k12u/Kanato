//
//  SettingsView.swift
//  Kanato
//

import SwiftUI

/// 設定画面。
///
/// 標準はアプリ内のローカルモデル（マニフェストの既定モデル = zenz-v3.2-small）で、
/// 未ダウンロードなら最上部に「ダウンロードして使う」を出す（このボタンが利用開始の意思表示）。
/// 外部 API やほかのモデルは「詳細設定」の中に置き、外部 API への切り替えには確認を求める。
struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var status: Status?
    @State private var isTesting = false
    /// 同梱のモデルマニフェスト（メタデータのみ）。読めない場合は nil
    @State private var manifest = try? ModelManifest.loadBundled()
    @State private var localModels: LocalModelController
    @State private var isShowingLicenses = false
    @State private var isShowingAdvanced = false
    /// 確認待ちのモード変更（外部 API への切り替え）
    @State private var pendingMode: DistributionMode?

    private enum Status {
        case success(String)
        case failure(String)
    }

    /// 動作テストに使う短文
    private static let testInput = "きょうはいいてんきです"

    init(settings: AppSettings = AppSettings(), localModels: LocalModelController = LocalModelController()) {
        _settings = State(initialValue: settings)
        _localModels = State(initialValue: localModels)
    }

    var body: some View {
        Form {
            Section("かな漢字変換") {
                primaryContent
                if canRunTest {
                    testRow
                }
            }

            Section {
                DisclosureGroup("詳細設定", isExpanded: $isShowingAdvanced) {
                    advancedContent
                }
            }

            Section {
                LabeledContent("Kanato", value: "MIT License")
                Button("ライセンス表示（同梱ソフトウェア・モデル）…") { isShowingLicenses = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "外部 API に切り替えますか？",
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible
        ) {
            Button("外部 API に切り替える") {
                if let pendingMode { settings.distributionMode = pendingMode }
                pendingMode = nil
            }
            Button("キャンセル", role: .cancel) { pendingMode = nil }
        } message: {
            Text("外部 API を使うと、変換のたびに選択した文字列を設定したサーバーへ送信します。標準のローカルモデル（この Mac 上で変換）は使われなくなります。切り替えは「保存」で確定します。")
        }
        .sheet(isPresented: $isShowingLicenses) {
            LicensesView(models: localInferenceModels)
        }
        .onAppear { localModels.refresh(localInferenceModels) }
        .frame(minWidth: 520, minHeight: 460)
    }

    // MARK: - かな漢字変換（標準）

    @ViewBuilder
    private var primaryContent: some View {
        switch settings.distributionMode {
        case .download:
            if let model = selectedLocalModel {
                localModelContent(model)
            } else {
                Label("ローカルモデルが見つかりません。詳細設定で選択してください。", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        case .external:
            externalSummary
        case .embedded:
            Label(InferenceBackendError.embeddedModeDisabled.errorDescription ?? "", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func localModelContent(_ model: ModelManifest.Model) -> some View {
        if localModels.downloadingModelID == model.id {
            HStack {
                ProgressView().controlSize(.small)
                Text("\(model.id) をダウンロードしています…")
                Spacer()
                Button("キャンセル") { localModels.cancelDownload() }
            }
        } else {
            switch localModels.state(of: model) {
            case .notInstalled:
                onboardingCard(model)
            case .installed:
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.id) で変換します")
                        Text("この Mac 上で変換します。選択した文字列は外部に送信されません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                ModelAttributionView(model: model)
            case .outdated, .incomplete:
                HStack {
                    Label("モデルの更新が必要です", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("更新する（再ダウンロード）") { download(model) }
                        .disabled(!localModels.isAvailable)
                }
                ModelAttributionView(model: model)
            }
        }
        if let message = localModels.errorMessage {
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }

    /// 初回の案内。「ダウンロードして使う」を押すことが利用開始の意思表示になる
    private func onboardingCard(_ model: ModelManifest.Model) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file)
        return VStack(alignment: .leading, spacing: 10) {
            Text("はじめに、変換モデルをダウンロードしてください")
                .font(.headline)
            Text("Kanato はかな漢字変換専用モデル「\(model.id)」を使い、この Mac 上で変換します。選択した文字列は外部に送信されません。")
                .fixedSize(horizontal: false, vertical: true)
            ModelAttributionView(model: model)
            Button {
                download(model)
            } label: {
                Text("ダウンロードして使う（\(size)）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!localModels.isAvailable || localModels.downloadingModelID != nil)
            Text("ボタンを押すと、Hugging Face の公式リポジトリからモデル（\(model.license.identifier)）を取得してこの Mac に保存し、標準の変換エンジンとして設定します。推論時のメモリは約 \(model.estimatedMemoryMB) MB です。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.license.downloadUseStatus != .verified {
                Label("このモデルはライセンスの確認が\(model.license.downloadUseStatus.displayName)のため、開発用（Debug）ビルドでのみ取得できます。",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    /// 外部 API を使っているときの概要。標準に戻す操作をここに置く
    @ViewBuilder
    private var externalSummary: some View {
        let isRemote = AppSettings.isRemote(baseURL: settings.baseURL)
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("外部 API で変換します")
                Text(isRemote
                     ? "選択した文字列を \(settings.baseURL) へ送信します。"
                     : "選択した文字列はこの Mac 上の LLM サーバーへ送信します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: isRemote ? "exclamationmark.triangle.fill" : "server.rack")
                .foregroundStyle(isRemote ? .orange : .secondary)
        }
        if hasUnsavedModeChange {
            Text("変更は未保存です。詳細設定の「保存」で確定します。")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if let model = defaultLocalModel {
            Button("標準（\(model.id)・この Mac 上で変換）に戻す") { returnToDefault(model) }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("動作テスト", action: runConnectionTest)
                    .disabled(isTesting)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
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

    // MARK: - 詳細設定

    @ViewBuilder
    private var advancedContent: some View {
        Picker("変換エンジン", selection: modeBinding) {
            Text("ローカルモデル（この Mac 上で変換）").tag(DistributionMode.download)
            Text("外部 API（OpenAI 互換サーバー）").tag(DistributionMode.external)
        }

        if settings.distributionMode == .download {
            if localInferenceModels.count > 1 {
                Picker("モデル", selection: $settings.localModelID) {
                    ForEach(localInferenceModels) { model in
                        Text(model.id == defaultLocalModel?.id ? "\(model.id)（標準）" : model.id).tag(model.id)
                    }
                }
            }
            if let model = selectedLocalModel, localModels.state(of: model) != .notInstalled {
                HStack {
                    Text("\(model.id)（\(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file))）")
                    Spacer()
                    Button("モデルを削除", role: .destructive) { localModels.delete(model) }
                        .disabled(localModels.downloadingModelID != nil)
                }
            }
        } else {
            externalSettings
        }

        Stepper(value: $settings.timeout, in: AppSettings.timeoutRange, step: 1) {
            LabeledContent("タイムアウト", value: "\(Int(settings.timeout)) 秒")
        }
        HStack {
            Spacer()
            Button("保存", action: save)
                .keyboardShortcut("s")
        }
    }

    @ViewBuilder
    private var externalSettings: some View {
        Picker("API形式", selection: $settings.apiFormat) {
            ForEach(ExternalAPIFormat.allCases, id: \.self) { format in
                Text(format.displayName).tag(format)
            }
        }
        TextField("API Base URL", text: $settings.baseURL, prompt: Text(AppSettings.defaultBaseURL))
            .autocorrectionDisabled()
        if settings.apiFormat != .chatCompletions {
            TextField("Model ID（任意）", text: $settings.model, prompt: Text("例: zenz-v2.5-medium"))
                .autocorrectionDisabled()
        } else {
            TextField("Model ID", text: $settings.model, prompt: Text("例: qwen2.5-7b-instruct"))
                .autocorrectionDisabled()
        }
        SecureField("API Key（任意）", text: $settings.apiKey)
        Toggle("temperature = 0 を送信する", isOn: $settings.sendTemperature)
        Toggle("ローカルネットワーク（.local / プライベートIP）へのHTTPを許可", isOn: $settings.allowLocalNetworkHTTP)
        Text("APIキーはKeychainに保存されます。入力・変換テキストは保存・ログ記録されません。")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// 外部 API への切り替えは確認ダイアログを経由する
    private var modeBinding: Binding<DistributionMode> {
        Binding(
            get: { settings.distributionMode },
            set: { newMode in
                if newMode == .external && settings.distributionMode != .external {
                    pendingMode = newMode
                } else {
                    settings.distributionMode = newMode
                }
            }
        )
    }

    // MARK: - Models

    /// ローカル推論で実行できるモデル（zenz の GGUF）
    private var localInferenceModels: [ModelManifest.Model] {
        (manifest?.models ?? []).filter(\.supportsLocalInference)
    }

    private var selectedLocalModel: ModelManifest.Model? {
        localInferenceModels.first { $0.id == settings.localModelID }
    }

    private var defaultLocalModel: ModelManifest.Model? {
        localInferenceModels.first { $0.id == manifest?.defaultModelID }
    }

    /// ローカルモデルが未ダウンロード（またはダウンロード中）のときは、動作テストを出さない
    private var canRunTest: Bool {
        guard settings.distributionMode == .download, let model = selectedLocalModel else { return true }
        return localModels.downloadingModelID != model.id && localModels.state(of: model) != .notInstalled
    }

    private var hasUnsavedModeChange: Bool {
        settings.distributionMode != AppSettings.loadBackendSelection().mode
    }

    // MARK: - Actions

    /// ダウンロードが成功したら、このモデルを使う設定として保存する
    private func download(_ model: ModelManifest.Model) {
        status = nil
        localModels.download(model) {
            settings.distributionMode = .download
            settings.localModelID = model.id
            settings.saveBackendSelection()
        }
    }

    private func returnToDefault(_ model: ModelManifest.Model) {
        settings.distributionMode = .download
        settings.localModelID = model.id
        settings.saveBackendSelection()
        status = nil
        localModels.refresh(localInferenceModels)
    }

    private func save() {
        if settings.save() {
            status = .success("保存しました")
        } else {
            status = .failure("APIキーをKeychainに保存できませんでした")
        }
    }

    /// 画面上の (未保存を含む) 設定で実際に小さな変換を行う
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

#Preview("保存済みの設定") {
    SettingsView()
}

#Preview("新規ユーザー") {
    let defaults = UserDefaults(suiteName: "org.k12u.Kanato.preview.new-user")!
    defaults.removePersistentDomain(forName: "org.k12u.Kanato.preview.new-user")
    let emptyModels = FileManager.default.temporaryDirectory.appending(path: "kanato-preview-models-\(UUID().uuidString)")
    return SettingsView(
        settings: AppSettings(defaults: defaults),
        localModels: LocalModelController(manager: ModelManager(rootDirectory: emptyModels))
    )
}
