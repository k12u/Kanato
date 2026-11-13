//
//  LocalModelBackend.swift
//  Kanato
//

import Foundation

/// ローカル推論エンジン（MLX Swift / llama.cpp など）を接続するための口。
/// エンジンは `ChatCompletionClient` として振る舞い、プロンプトと出力検証は外部 API と同じ
/// `ConversionService` を通す。これにより変換品質の条件をバックエンド間でそろえる。
nonisolated protocol LocalInferenceEngine: ChatCompletionClient {
    static var backendKind: ModelManifest.BackendKind { get }
    static var supportedFormats: Set<ModelManifest.ModelFormat> { get }

    /// 検証済みのモデルディレクトリからエンジンを生成する（モデルのロードを含む）
    init(model: ModelManifest.Model, directory: URL) async throws
}

/// 利用可能なローカル推論エンジンの登録先。
/// 現時点では未実装のため空。エンジンを追加したら `engineTypes` に登録する。
nonisolated enum LocalInferenceEngines {
    static let engineTypes: [any LocalInferenceEngine.Type] = []

    static func engineType(for kind: ModelManifest.BackendKind) -> (any LocalInferenceEngine.Type)? {
        engineTypes.first { $0.backendKind == kind }
    }
}

/// Download（将来は Embedded も）で取得したモデルを、ローカル推論エンジンで実行するバックエンド。
/// エンジンが未実装の場合は `localInferenceNotImplemented` を返し、外部 API へはフォールバックしない。
nonisolated struct LocalModelBackend: InferenceBackend {
    let model: ModelManifest.Model
    let directory: URL
    var engineType: (any LocalInferenceEngine.Type)?

    init(
        model: ModelManifest.Model,
        directory: URL,
        engineType: (any LocalInferenceEngine.Type)? = nil
    ) {
        self.model = model
        self.directory = directory
        self.engineType = engineType ?? LocalInferenceEngines.engineType(for: model.backend)
    }

    func convert(_ text: String) async throws -> String {
        guard let engineType, engineType.supportedFormats.contains(model.format) else {
            throw InferenceBackendError.localInferenceNotImplemented(model.backend)
        }
        // TODO: エンジン実装時にロード済みエンジンをキャッシュする（変換ごとのロードは避ける）
        let engine = try await engineType.init(model: model, directory: directory)
        return try await ConversionService(client: engine).convert(text: text)
    }
}
