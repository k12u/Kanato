//
//  ModelManagerTests.swift
//  KanatoTests
//

import CryptoKit
import Foundation
import Testing
@testable import Kanato

/// パスごとに固定のファイル内容（または HTTP エラー）を返す URLProtocol スタブ
nonisolated final class ModelFileURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var failingPaths: Set<String> = []
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        Self.requestedPaths.append(path)
        let body = Self.failingPaths.contains(path) ? nil : Self.files[path]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("not found".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum ModelFixtures {
    static let revision = "0123456789abcdef0123456789abcdef01234567"
    static let weights = Data("fake weights for tests".utf8)
    static let license = Data("Apache License 2.0 (test)".utf8)

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func model(
        id: String = "test-model",
        status: ModelManifest.RedistributionStatus = .unverified,
        weightsHash: String? = nil,
        format: ModelManifest.ModelFormat = .gguf,
        promptFormat: ModelManifest.PromptFormat? = nil
    ) -> ModelManifest.Model {
        ModelManifest.Model(
            id: id,
            name: "Test Model",
            source: .init(
                repositoryURL: URL(string: "https://example.com/org/repo")!,
                revision: revision,
                downloadBaseURL: URL(string: "https://example.com/org/repo/resolve/\(revision)")!
            ),
            files: [
                .init(path: "model.gguf", sha256: weightsHash ?? sha256(weights), size: Int64(weights.count)),
                .init(path: "LICENSE", sha256: sha256(license), size: Int64(license.count)),
            ],
            license: .init(identifier: "Apache-2.0", documentPath: "LICENSE", redistribution: status, notes: nil),
            backend: .llamaCpp,
            format: format,
            quantization: "Q4_K_M",
            estimatedMemoryMB: 1024,
            promptFormat: promptFormat
        )
    }
}

@Suite(.serialized)
struct ModelManagerTests {
    let root: URL
    let manager: ModelManager

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "KanatoModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelFileURLProtocol.self]
        manager = ModelManager(
            rootDirectory: root,
            session: URLSession(configuration: configuration),
            allowsUnverifiedLicenses: true
        )
        ModelFileURLProtocol.files = ["model.gguf": ModelFixtures.weights, "LICENSE": ModelFixtures.license]
        ModelFileURLProtocol.failingPaths = []
        ModelFileURLProtocol.requestedPaths = []
    }

    private func stagingContents() -> [String] {
        let staging = root.appending(path: ModelManager.stagingDirectoryName)
        return (try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? []
    }

    @Test func downloadVerifiesAndInstalls() async throws {
        let model = ModelFixtures.model()
        #expect(manager.installState(of: model) == .notInstalled)

        let installed = try await manager.download(model)

        #expect(installed.id == model.id)
        #expect(installed.revision == ModelFixtures.revision)
        #expect(manager.installState(of: model) == .installed)
        #expect(manager.installedModels().map(\.id) == [model.id])
        #expect(manager.missingFiles(of: model).isEmpty)
        #expect(manager.storageUsage() > 0)
        #expect(stagingContents().isEmpty)
        // ライセンス文書もモデルと一緒に保存される
        let licenseURL = installed.directory.appending(path: "LICENSE")
        #expect(try Data(contentsOf: licenseURL) == ModelFixtures.license)
        try await manager.verify(model)
    }

    @Test func requestsPinnedRevisionURL() async throws {
        let model = ModelFixtures.model()
        #expect(model.source.downloadURL(for: model.files[0]).absoluteString
                == "https://example.com/org/repo/resolve/\(ModelFixtures.revision)/model.gguf")
        try await manager.download(model)
        #expect(ModelFileURLProtocol.requestedPaths == ["model.gguf", "LICENSE"])
    }

    @Test func checksumMismatchLeavesNothingInstalled() async throws {
        let model = ModelFixtures.model(weightsHash: String(repeating: "0", count: 64))
        await #expect(throws: ModelStoreError.checksumMismatch("model.gguf")) {
            try await manager.download(model)
        }
        #expect(manager.installState(of: model) == .notInstalled)
        #expect(manager.installedModels().isEmpty)
        #expect(stagingContents().isEmpty)
    }

    @Test func httpFailureCleansUp() async throws {
        ModelFileURLProtocol.failingPaths = ["LICENSE"]
        let model = ModelFixtures.model()
        await #expect(throws: ModelStoreError.httpStatus("LICENSE", 404)) {
            try await manager.download(model)
        }
        #expect(manager.installState(of: model) == .notInstalled)
        #expect(stagingContents().isEmpty)
    }

    @Test func failedRedownloadKeepsExistingInstall() async throws {
        let model = ModelFixtures.model()
        try await manager.download(model)

        ModelFileURLProtocol.failingPaths = ["model.gguf"]
        await #expect(throws: ModelStoreError.self) { try await manager.download(model) }

        #expect(manager.installState(of: model) == .installed)
        try await manager.verify(model)
    }

    @Test func redownloadReplacesExistingInstall() async throws {
        let model = ModelFixtures.model()
        try await manager.download(model)
        try await manager.download(model)
        #expect(manager.installState(of: model) == .installed)
        #expect(stagingContents().isEmpty)
    }

    @Test func verifyDetectsTamperedFile() async throws {
        let model = ModelFixtures.model()
        let installed = try await manager.download(model)
        // サイズを変えずに内容だけ書き換える
        var tampered = ModelFixtures.weights
        tampered[0] ^= 0xFF
        try tampered.write(to: installed.directory.appending(path: "model.gguf"))

        #expect(manager.installState(of: model) == .installed)
        await #expect(throws: ModelStoreError.checksumMismatch("model.gguf")) {
            try await manager.verify(model)
        }
    }

    @Test func detectsMissingAndOutdatedFiles() async throws {
        let model = ModelFixtures.model()
        let installed = try await manager.download(model)
        try FileManager.default.removeItem(at: installed.directory.appending(path: "model.gguf"))
        #expect(manager.installState(of: model) == .incomplete(missingFiles: ["model.gguf"]))
        await #expect(throws: ModelStoreError.missingFile("model.gguf")) { try await manager.verify(model) }

        var updated = model
        updated.source.revision = "fedcba9876543210fedcba9876543210fedcba98"
        #expect(manager.installState(of: updated) == .outdated(installedRevision: ModelFixtures.revision))
    }

    @Test func directoryWithoutReceiptIsNotInstalled() throws {
        let model = ModelFixtures.model()
        let directory = try manager.directory(for: model.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ModelFixtures.weights.write(to: directory.appending(path: "model.gguf"))
        try ModelFixtures.license.write(to: directory.appending(path: "LICENSE"))

        #expect(manager.installState(of: model) == .notInstalled)
        #expect(manager.installedModels().isEmpty)
    }

    /// scripts/download-model.sh が書く receipt（jq 出力・秒精度 UTC）をアプリ側でも認識する
    @Test func recognizesReceiptWrittenByScript() throws {
        let model = ModelFixtures.model()
        let directory = try manager.directory(for: model.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ModelFixtures.weights.write(to: directory.appending(path: "model.gguf"))
        try ModelFixtures.license.write(to: directory.appending(path: "LICENSE"))
        let files = try String(decoding: JSONEncoder().encode(model.files), as: UTF8.self)
        let receipt = """
        {"schemaVersion":1,"modelID":"\(model.id)","revision":"\(ModelFixtures.revision)",
         "files":\(files),"installedAt":"2026-11-13T14:37:54Z"}
        """
        try Data(receipt.utf8).write(to: directory.appending(path: ModelManager.receiptFileName))

        #expect(manager.installState(of: model) == .installed)
    }

    @Test func deleteRemovesModel() async throws {
        let model = ModelFixtures.model()
        try await manager.download(model)
        try manager.delete(modelID: model.id)
        #expect(manager.installState(of: model) == .notInstalled)
        #expect(manager.storageUsage(of: model.id) == 0)
        #expect(throws: ModelStoreError.notInstalled(model.id)) { try manager.delete(modelID: model.id) }
    }

    @Test func rejectsPathTraversalIDs() {
        #expect(throws: ModelStoreError.invalidModelID) { try manager.delete(modelID: "../outside") }
        #expect(throws: ModelStoreError.invalidModelID) { try manager.directory(for: ".staging") }
    }

    @Test func releasePolicyRejectsUnverifiedLicense() async throws {
        let strict = ModelManager(rootDirectory: root, allowsUnverifiedLicenses: false)
        for status in [ModelManifest.RedistributionStatus.unverified, .inReview] {
            let model = ModelFixtures.model(status: status)
            await #expect(throws: ModelStoreError.licenseNotVerified(model.id, status)) {
                try await strict.download(model)
            }
        }
        #expect(ModelFileURLProtocol.requestedPaths.isEmpty)
    }

    @Test func cleanUpStagingRemovesLeftovers() throws {
        let leftover = root.appending(path: ModelManager.stagingDirectoryName).appending(path: "test-model-crashed")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        manager.cleanUpStaging()
        #expect(!FileManager.default.fileExists(atPath: leftover.path(percentEncoded: false)))
    }
}
