//
//  LocalModelBackendTests.swift
//  KanatoTests
//

import Foundation
import Testing
@testable import Kanato

/// 読み込み回数とプロンプトを記録するモックエンジン
nonisolated final class MockLocalEngine: LocalInferenceEngine, @unchecked Sendable {
    static let backendKind: ModelManifest.BackendKind = .llamaCpp
    static let supportedFormats: Set<ModelManifest.ModelFormat> = [.gguf]

    nonisolated(unsafe) static var loadCount = 0
    nonisolated(unsafe) static var prompts: [String] = []
    nonisolated(unsafe) static var failsToLoad = false

    init(model: ModelManifest.Model, directory: URL) throws {
        if Self.failsToLoad { throw InferenceBackendError.modelLoadFailed(model.id) }
        Self.loadCount += 1
    }

    func completeText(prompt: String, maxTokens: Int) async throws -> String {
        Self.prompts.append(prompt)
        return "テスト"
    }

    static func reset() {
        loadCount = 0
        prompts = []
        failsToLoad = false
    }
}

@Suite(.serialized)
struct LocalModelBackendTests {
    private let directory = URL(filePath: "/tmp/kanato-local-model-tests")

    init() {
        MockLocalEngine.reset()
    }

    private func backend(
        _ model: ModelManifest.Model,
        cache: LocalEngineCache = LocalEngineCache(),
        engineType: (any LocalInferenceEngine.Type)? = MockLocalEngine.self
    ) -> LocalModelBackend {
        var backend = LocalModelBackend(model: model, directory: directory, engineType: engineType, cache: cache)
        backend.engineType = engineType
        return backend
    }

    @Test func convertsWithZenzV3PromptAndReusesLoadedEngine() async throws {
        let cache = LocalEngineCache()
        let model = ModelFixtures.model(promptFormat: .zenzV3)
        #expect(try await backend(model, cache: cache).convert("てすと") == "テスト")
        // モックは常に「テスト」を返すため、かなの部分（「のてすと」）が「テスト」に置き換わる
        #expect(try await backend(model, cache: cache).convert("Appleのてすと") == "Appleテスト")
        #expect(MockLocalEngine.loadCount == 1)
        // v3 は左文脈が入力より前
        #expect(MockLocalEngine.prompts == ["\u{EE00}テスト\u{EE01}", "\u{EE02}Apple\u{EE00}ノテスト\u{EE01}"])
    }

    @Test func reloadsWhenModelChangesAndAfterRemoveAll() async throws {
        let cache = LocalEngineCache()
        _ = try await backend(ModelFixtures.model(id: "model-a", promptFormat: .zenzV3), cache: cache).convert("てすと")
        _ = try await backend(ModelFixtures.model(id: "model-b", promptFormat: .zenzV3), cache: cache).convert("てすと")
        cache.removeAll()
        _ = try await backend(ModelFixtures.model(id: "model-b", promptFormat: .zenzV3), cache: cache).convert("てすと")
        #expect(MockLocalEngine.loadCount == 3)
    }

    @Test func usesV2PromptForZenzV2Models() async throws {
        _ = try await backend(ModelFixtures.model(promptFormat: .zenzV2)).convert("Appleのてすと")
        #expect(MockLocalEngine.prompts == ["\u{EE00}ノテスト\u{EE02}Apple\u{EE01}"])
    }

    @Test func rejectsUnsupportedConfigurations() async {
        await #expect(throws: InferenceBackendError.unsupportedPromptFormat("test-model")) {
            try await backend(ModelFixtures.model(promptFormat: .chat)).convert("てすと")
        }
        await #expect(throws: InferenceBackendError.unsupportedModelFormat(.safetensors)) {
            try await backend(ModelFixtures.model(format: .safetensors, promptFormat: .zenzV2)).convert("てすと")
        }
        await #expect(throws: InferenceBackendError.localInferenceNotImplemented(.llamaCpp)) {
            try await backend(ModelFixtures.model(promptFormat: .zenzV3), engineType: nil).convert("てすと")
        }
        #expect(MockLocalEngine.loadCount == 0)
    }

    @Test func reportsLoadFailure() async {
        MockLocalEngine.failsToLoad = true
        await #expect(throws: InferenceBackendError.modelLoadFailed("test-model")) {
            try await backend(ModelFixtures.model(promptFormat: .zenzV3)).convert("てすと")
        }
    }

    /// 実ファイルがないと llama.cpp の読み込みは失敗し、明確なエラーになる
    @Test func llamaCppEngineReportsMissingFile() {
        let model = ModelFixtures.model(promptFormat: .zenzV3)
        #expect(throws: InferenceBackendError.modelLoadFailed("test-model")) {
            try LlamaCppEngine(model: model, directory: URL(filePath: "/nonexistent"))
        }
    }
}
