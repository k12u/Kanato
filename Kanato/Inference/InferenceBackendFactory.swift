//
//  InferenceBackendFactory.swift
//  Kanato
//

import Foundation

/// モデルの配布モード。推論バックエンドの選択もこれで決まる。
nonisolated enum DistributionMode: String, CaseIterable, Sendable {
    /// ユーザーが設定した外部推論 API（OpenAI 互換）を使う。MVP で動作する唯一のモード
    case external
    /// 初回実行時にマニフェストのモデルを Application Support へ取得し、ローカル推論する
    case download
    /// ビルド時に確認済みモデルを同梱する。モデル選定とライセンス確認後に有効化する
    case embedded


    var displayName: String {
        switch self {
        case .external: "External（外部API）"
        case .download: "Download（ローカルモデル）"
        case .embedded: "Embedded（同梱モデル）"
        }
    }

    /// Embedded は同梱できるモデル（ライセンス確認済み）が決まるまで無効
    var isEnabled: Bool {
        self != .embedded
    }
}

/// External モードで使う API の形式
nonisolated enum ExternalAPIFormat: String, CaseIterable, Sendable {
    /// Chat Completions（`/chat/completions`）。汎用 LLM にシステムプロンプトで変換を指示する
    case chatCompletions = "chat"
    /// zenz v2 系の Completions（`/completions`）。かな漢字変換専用モデル zenz-v2.5 など
    case zenz
    /// zenz v3 系の Completions（`/completions`）。zenz-v3.x
    case zenzV3 = "zenz-v3"

    static let `default`: ExternalAPIFormat = .chatCompletions

    var displayName: String {
        switch self {
        case .chatCompletions: "Chat Completions（汎用LLM）"
        case .zenz: "zenz v2（かな漢字変換モデル）"
        case .zenzV3: "zenz v3（かな漢字変換モデル）"
        }
    }
}

/// 設定値から推論バックエンドを選ぶ
nonisolated struct BackendSelection: Equatable, Sendable {
    var mode: DistributionMode
    /// Download / Embedded で使う Model ID（マニフェストの `id`）
    var localModelID: String
    var externalFormat: ExternalAPIFormat = .default
}

/// 設定に応じたバックエンドを生成する。選択された構成が使えない場合は理由を返す
/// `UnavailableBackend` を生成し、別のバックエンドへ暗黙にフォールバックしない。
nonisolated struct InferenceBackendFactory: Sendable {
    var loadManifest: @Sendable () throws -> ModelManifest = { try ModelManifest.loadBundled() }
    var makeModelManager: @Sendable () throws -> ModelManager = { try ModelManager.makeDefault() }
    var makeClient: @Sendable (LLMConfiguration) -> any ChatCompletionClient = { OpenAICompatibleClient(configuration: $0) }
    var makeTextClient: @Sendable (LLMConfiguration) -> any TextCompletionClient = { OpenAICompatibleClient(configuration: $0) }

    func makeBackend(selection: BackendSelection, configuration: LLMConfiguration) -> any InferenceBackend {
        switch selection.mode {
        case .external:
            switch selection.externalFormat {
            case .chatCompletions:
                return ExternalAPIBackend(client: makeClient(configuration))
            case .zenz:
                return ZenzBackend(client: makeTextClient(configuration), promptVersion: .v2)
            case .zenzV3:
                return ZenzBackend(client: makeTextClient(configuration), promptVersion: .v3)
            }
        case .embedded:
            return UnavailableBackend(error: .embeddedModeDisabled)
        case .download:
            do {
                return try makeDownloadedModelBackend(modelID: selection.localModelID)
            } catch let error as InferenceBackendError {
                return UnavailableBackend(error: error)
            } catch {
                return UnavailableBackend(error: .modelNotInstalled(selection.localModelID))
            }
        }
    }

    private func makeDownloadedModelBackend(modelID: String) throws -> any InferenceBackend {
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw InferenceBackendError.localModelNotSelected }
        guard let manifest = try? loadManifest() else { throw InferenceBackendError.manifestUnavailable }
        guard let model = manifest.model(id: modelID) else { throw InferenceBackendError.modelNotInManifest(modelID) }

        let manager = try makeModelManager()
        switch manager.installState(of: model) {
        case .installed:
            return LocalModelBackend(model: model, directory: try manager.directory(for: model.id))
        case .notInstalled, .incomplete:
            throw InferenceBackendError.modelNotInstalled(modelID)
        case .outdated:
            throw InferenceBackendError.modelOutdated(modelID)
        }
    }
}
