//
//  ModelManifestTests.swift
//  KanatoTests
//

import Foundation
import Testing
@testable import Kanato

struct ModelManifestTests {

    private func manifest(_ models: [ModelManifest.Model]) -> ModelManifest {
        ModelManifest(schemaVersion: ModelManifest.supportedSchemaVersion, models: models)
    }

    private func expectInvalid(_ model: ModelManifest.Model) {
        #expect(throws: ModelManifestError.self) { try manifest([model]).validate() }
    }

    @Test func bundledManifestLoads() throws {
        let bundled = try ModelManifest.loadBundled(from: Bundle(for: AppDelegate.self))
        #expect(bundled.schemaVersion == ModelManifest.supportedSchemaVersion)
    }

    @Test func roundTripsJSON() throws {
        let original = manifest([ModelFixtures.model(status: .inReview)])
        let data = try JSONEncoder().encode(original)
        #expect(try ModelManifest.decode(data) == original)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""redistribution":"in-review""#))
        #expect(json.contains(#""backend":"llama.cpp""#))
    }

    @Test func onlyVerifiedModelsAreEmbeddable() {
        let models = ModelManifest.RedistributionStatus.allCases.map {
            ModelFixtures.model(id: "model-\($0.rawValue)", status: $0)
        }
        #expect(manifest(models).embeddableModels.map(\.id) == ["model-verified"])
    }

    @Test func rejectsUnsafeFilePaths() {
        for path in ["../escape.gguf", "/abs/model.gguf", "dir/../x", ".hidden", "a//b", ""] {
            var model = ModelFixtures.model()
            model.files[0].path = path
            expectInvalid(model)
        }
    }

    @Test func rejectsInvalidModels() {
        var model = ModelFixtures.model()
        model.id = "../x"
        expectInvalid(model)

        model = ModelFixtures.model()
        model.files[0].sha256 = "ABC"
        expectInvalid(model)

        model = ModelFixtures.model()
        model.license.documentPath = "NOT_LISTED"
        expectInvalid(model)

        model = ModelFixtures.model()
        model.source.revision = "main/latest"
        expectInvalid(model)

        // revision を含まない（固定されていない）取得元
        model = ModelFixtures.model()
        model.source.downloadBaseURL = URL(string: "https://example.com/org/repo/resolve/main")!
        expectInvalid(model)

        model = ModelFixtures.model()
        model.source.downloadBaseURL = URL(string: "http://example.com/org/repo/resolve/\(ModelFixtures.revision)")!
        expectInvalid(model)

        let duplicate = ModelFixtures.model()
        #expect(throws: ModelManifestError.self) { try manifest([duplicate, duplicate]).validate() }
    }

    @Test func bundledZenzV3ModelIsConfiguredForLlamaCpp() throws {
        let bundled = try ModelManifest.loadBundled(from: Bundle(for: AppDelegate.self))
        let zenz = try #require(bundled.model(id: "zenz-v3.2-small"))
        #expect(zenz.format == .gguf)
        #expect(zenz.promptFormat == .zenzV3)
        #expect(zenz.contextLength == 1024)
        #expect(zenz.metadataOverrides == ["tokenizer.ggml.pre": "gpt-2"])
        // 再配布可否が確認されるまでは同梱対象にしない
        #expect(!bundled.embeddableModels.contains { $0.id == zenz.id })
    }

    @Test func rejectsInvalidInferenceSettings() {
        var model = ModelFixtures.model()
        model.contextLength = 0
        expectInvalid(model)

        model = ModelFixtures.model()
        model.metadataOverrides = [String(repeating: "k", count: 128): "v"]
        expectInvalid(model)

        model = ModelFixtures.model()
        model.metadataOverrides = ["": "v"]
        expectInvalid(model)
    }

    @Test func rejectsUnsupportedSchemaVersion() {
        #expect(throws: ModelManifestError.unsupportedSchemaVersion(99)) {
            try ModelManifest.decode(Data(#"{"schemaVersion":99,"models":[]}"#.utf8))
        }
    }
}
