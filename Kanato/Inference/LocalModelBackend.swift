//
//  LocalModelBackend.swift
//  Kanato
//

import Foundation

/// ローカル推論エンジン（llama.cpp など）の共通インターフェース。
/// エンジンはプロンプトの続きを生成する `TextCompletionClient` として振る舞い、
/// プロンプトの組み立て・入出力の検証は外部 API と同じ `ZenzBackend` が行う。
nonisolated protocol LocalInferenceEngine: TextCompletionClient {
    static var backendKind: ModelManifest.BackendKind { get }
    static var supportedFormats: Set<ModelManifest.ModelFormat> { get }

    /// 検証済みのモデルディレクトリからモデルを読み込む
    init(model: ModelManifest.Model, directory: URL) throws
}

/// 利用可能なローカル推論エンジンの登録先
nonisolated enum LocalInferenceEngines {
    static let engineTypes: [any LocalInferenceEngine.Type] = [LlamaCppEngine.self]

    static func engineType(for kind: ModelManifest.BackendKind) -> (any LocalInferenceEngine.Type)? {
        engineTypes.first { $0.backendKind == kind }
    }
}

/// 読み込み済みのエンジンを 1 つだけ保持する。変換のたびにモデルを読み込まないためのもの。
/// 別のモデル（または別のリビジョン・保存先）が要求されたら差し替える。
nonisolated final class LocalEngineCache: @unchecked Sendable {
    static let shared = LocalEngineCache()

    private let lock = NSLock()
    private var current: (key: String, engine: any LocalInferenceEngine)?

    func engine(
        for model: ModelManifest.Model,
        directory: URL,
        type engineType: any LocalInferenceEngine.Type
    ) throws -> any LocalInferenceEngine {
        let key = "\(engineType)|\(model.id)|\(model.source.revision)|\(directory.path(percentEncoded: false))"
        return try lock.withLock {
            if let current, current.key == key { return current.engine }
            current = nil  // 先に解放してから読み込む（2 モデル分のメモリを同時に使わない）
            let engine = try engineType.init(model: model, directory: directory)
            current = (key, engine)
            return engine
        }
    }

    /// モデルの削除・更新時に呼び、ファイルを参照しているエンジンを解放する
    func removeAll() {
        lock.withLock { current = nil }
    }
}

/// Download（将来は Embedded も）で取得したモデルを、ローカル推論エンジンで実行するバックエンド。
/// 使えない構成（エンジン未登録・未対応のモデル形式・チャット形式のモデル）は明確なエラーを返し、
/// 外部 API へはフォールバックしない。
nonisolated struct LocalModelBackend: InferenceBackend {
    let model: ModelManifest.Model
    let directory: URL
    var engineType: (any LocalInferenceEngine.Type)?
    var cache: LocalEngineCache

    init(
        model: ModelManifest.Model,
        directory: URL,
        engineType: (any LocalInferenceEngine.Type)? = nil,
        cache: LocalEngineCache = .shared
    ) {
        self.model = model
        self.directory = directory
        self.engineType = engineType ?? LocalInferenceEngines.engineType(for: model.backend)
        self.cache = cache
    }

    func convert(_ text: String) async throws -> String {
        guard let engineType else {
            throw InferenceBackendError.localInferenceNotImplemented(model.backend)
        }
        guard engineType.supportedFormats.contains(model.format) else {
            throw InferenceBackendError.unsupportedModelFormat(model.format)
        }
        let version: ZenzBackend.PromptVersion
        switch model.promptFormat {
        case .zenzV2: version = .v2
        case .zenzV3: version = .v3
        case .chat, nil: throw InferenceBackendError.unsupportedPromptFormat(model.id)
        }
        let engine = try cache.engine(for: model, directory: directory, type: engineType)
        return try await ZenzBackend(client: engine, promptVersion: version).convert(text)
    }
}

nonisolated extension ModelManifest.Model {
    /// アプリ内のローカル推論で実行できるか（エンジンが対応する形式で、zenz のプロンプト形式を持つ）
    var supportsLocalInference: Bool {
        guard let engineType = LocalInferenceEngines.engineType(for: backend),
              engineType.supportedFormats.contains(format)
        else { return false }
        return promptFormat == .zenzV2 || promptFormat == .zenzV3
    }
}
