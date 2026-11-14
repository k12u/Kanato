//
//  InferenceBackend.swift
//  Kanato
//

import Foundation

/// かな漢字変換を行う推論バックエンドの共通インターフェース。
/// 外部 API・ローカル推論のどちらでも、入力の検証・プロンプト・出力検証は実装側が責任を持つ。
nonisolated protocol InferenceBackend: Sendable {
    func convert(_ text: String) async throws -> String
}

/// External: ユーザーが設定した OpenAI 互換 API（LM Studio・開発用 Mock Server など）で変換する
nonisolated struct ExternalAPIBackend: InferenceBackend {
    let service: ConversionService

    init(client: any ChatCompletionClient) {
        service = ConversionService(client: client)
    }

    init(configuration: LLMConfiguration) {
        self.init(client: OpenAICompatibleClient(configuration: configuration))
    }

    func convert(_ text: String) async throws -> String {
        try await service.convert(text: text)
    }
}

/// 選択されたモードが利用できない場合に、理由をそのままエラーとして返すバックエンド。
/// 未実装・未設定の構成を黙って別の経路にフォールバックさせないために使う。
nonisolated struct UnavailableBackend: InferenceBackend {
    let error: InferenceBackendError

    func convert(_ text: String) async throws -> String {
        throw error
    }
}

nonisolated enum InferenceBackendError: LocalizedError, Equatable, Sendable {
    /// ローカル推論エンジンが未実装（MLX Swift / llama.cpp は評価中）
    case localInferenceNotImplemented(ModelManifest.BackendKind)
    /// Embedded はモデル選定とライセンス確認が済むまで無効
    case embeddedModeDisabled
    case localModelNotSelected
    case modelNotInManifest(String)
    case modelNotInstalled(String)
    case modelOutdated(String)
    case manifestUnavailable
    /// モデルのプロンプト形式がローカル推論に対応していない（チャット形式など）
    case unsupportedPromptFormat(String)
    /// モデルファイルの形式が推論エンジンに対応していない（変換前の safetensors など）
    case unsupportedModelFormat(ModelManifest.ModelFormat)
    case modelLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .localInferenceNotImplemented(let kind):
            "ローカル推論（\(kind.displayName)）は未実装です。設定で「External（外部API）」を選択してください"
        case .embeddedModeDisabled:
            "Embedded モードは未有効化です（モデル選定とライセンス確認後に有効化されます）"
        case .localModelNotSelected: "ローカルモデルが選択されていません"
        case .modelNotInManifest(let id): "モデル \(id) はモデルマニフェストに登録されていません"
        case .modelNotInstalled(let id): "モデル \(id) はダウンロードされていません"
        case .modelOutdated(let id): "モデル \(id) はマニフェストと一致しません。再ダウンロードしてください"
        case .manifestUnavailable: "モデルマニフェストを読み込めません"
        case .unsupportedPromptFormat(let id): "モデル \(id) の形式はローカル推論に未対応です（対応: zenz）"
        case .unsupportedModelFormat(let format): "\(format.rawValue) 形式のモデルはローカル推論で読み込めません（GGUF が必要です）"
        case .modelLoadFailed(let id): "モデル \(id) を読み込めませんでした"
        }
    }
}
