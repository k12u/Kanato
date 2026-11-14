//
//  InferenceBackendTests.swift
//  KanatoTests
//

import Foundation
import Testing
@testable import Kanato

@Suite(.serialized)
struct InferenceBackendTests {
    private struct EchoClient: ChatCompletionClient {
        func complete(system: String, user: String) async throws -> String { "変換:\(user)" }
    }

    private static let configuration = LLMConfiguration(
        baseURL: "http://127.0.0.1:8765/v1", model: "kanafilter-mock", apiKey: nil,
        timeout: 2, temperature: 0, allowLocalNetworkHTTP: false
    )

    private let root = FileManager.default.temporaryDirectory
        .appending(path: "KanatoBackendTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeFactory(models: [ModelManifest.Model] = [ModelFixtures.model()]) -> InferenceBackendFactory {
        let root = root
        var factory = InferenceBackendFactory()
        factory.loadManifest = { ModelManifest(schemaVersion: 1, models: models) }
        factory.makeModelManager = { ModelManager(rootDirectory: root) }
        factory.makeClient = { _ in EchoClient() }
        return factory
    }

    /// ダウンロード済みと同じレイアウト（ファイル + receipt）を直接作る
    private func install(_ model: ModelManifest.Model, using manager: ModelManager) throws {
        let directory = try manager.directory(for: model.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ModelFixtures.weights.write(to: directory.appending(path: "model.gguf"))
        try ModelFixtures.license.write(to: directory.appending(path: "LICENSE"))
        let receipt = ModelInstallReceipt(
            schemaVersion: ModelInstallReceipt.currentSchemaVersion, modelID: model.id,
            revision: model.source.revision, files: model.files, installedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: directory.appending(path: ModelManager.receiptFileName))
    }

    private func convert(_ mode: DistributionMode, modelID: String = "test-model", factory: InferenceBackendFactory? = nil) async throws -> String {
        let backend = (factory ?? makeFactory()).makeBackend(
            selection: BackendSelection(mode: mode, localModelID: modelID),
            configuration: Self.configuration
        )
        return try await backend.convert("てすと")
    }

    @Test func externalUsesConfiguredClientAndValidation() async throws {
        #expect(try await convert(.external) == "変換:てすと")
        // 既存の入力検証を通る
        let backend = ExternalAPIBackend(client: EchoClient())
        await #expect(throws: ConversionError.emptyInput) { try await backend.convert("  ") }
    }

    @Test func embeddedIsDisabled() async {
        #expect(!DistributionMode.embedded.isEnabled)
        await #expect(throws: InferenceBackendError.embeddedModeDisabled) { try await convert(.embedded) }
    }

    @Test func downloadReportsMissingSetup() async {
        await #expect(throws: InferenceBackendError.localModelNotSelected) { try await convert(.download, modelID: "") }
        await #expect(throws: InferenceBackendError.modelNotInManifest("unknown")) { try await convert(.download, modelID: "unknown") }
        await #expect(throws: InferenceBackendError.modelNotInstalled("test-model")) { try await convert(.download) }

        var factory = makeFactory()
        factory.loadManifest = { throw ModelManifestError.notFound }
        await #expect(throws: InferenceBackendError.manifestUnavailable) { try await convert(.download, factory: factory) }
    }

    /// チャット形式（プロンプト形式なし）のモデルはローカル推論に使えず、外部 API へはフォールバックしない
    @Test func installedChatModelFailsClearly() async throws {
        let factory = makeFactory()
        try install(ModelFixtures.model(), using: factory.makeModelManager())

        let backend = factory.makeBackend(
            selection: BackendSelection(mode: .download, localModelID: "test-model"),
            configuration: Self.configuration
        )
        #expect(backend is LocalModelBackend)
        await #expect(throws: InferenceBackendError.unsupportedPromptFormat("test-model")) {
            try await backend.convert("てすと")
        }
        #expect(LocalInferenceEngines.engineType(for: .llamaCpp).map(ObjectIdentifier.init) == ObjectIdentifier(LlamaCppEngine.self))
        #expect(LocalInferenceEngines.engineType(for: .mlx) == nil)
    }

    @Test func savedSelectionDefaultsToExternal() throws {
        let defaults = try #require(UserDefaults(suiteName: "org.k12u.KanatoTests.\(UUID().uuidString)"))
        #expect(AppSettings.loadBackendSelection(defaults: defaults).mode == .external)
        defaults.set("no-such-mode", forKey: "distributionMode")
        #expect(AppSettings.loadBackendSelection(defaults: defaults).mode == .external)
        defaults.set("download", forKey: "distributionMode")
        defaults.set("test-model", forKey: "localModelID")
        #expect(AppSettings.loadBackendSelection(defaults: defaults) == BackendSelection(mode: .download, localModelID: "test-model"))
    }
}
