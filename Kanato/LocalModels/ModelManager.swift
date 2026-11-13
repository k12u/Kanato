//
//  ModelManager.swift
//  Kanato
//

import CryptoKit
import Foundation
import os

/// ダウンロード済みモデルの保存・検証・削除を行う。
///
/// 保存先: `<rootDirectory>/<Model ID>/`（既定は Application Support/Kanato/Models）
/// - 取得は `<rootDirectory>/.staging/` 内の一時ディレクトリで行い、全ファイルのサイズと SHA-256 を
///   検証してインストール記録（receipt）を書いてから、最終位置へ移動（置換）する。
/// - receipt がないディレクトリはインストール済みとして扱わない。途中で失敗した一時ディレクトリは削除する。
/// - `scripts/download-model.sh` も同じレイアウトと receipt 形式で保存する。
nonisolated final class ModelManager: Sendable {
    /// モデルディレクトリ内のインストール記録。マニフェストのファイルパスは隠しファイルを許可しないため衝突しない
    static let receiptFileName = ".kanato-install.json"
    static let stagingDirectoryName = ".staging"

    let rootDirectory: URL
    /// 再配布可否が未確認・確認中のモデルの取得を許可するか（開発用）
    let allowsUnverifiedLicenses: Bool
    private let session: URLSession
    private let activeDownloads = OSAllocatedUnfairLock(initialState: Set<String>())

    private static let logger = Logger(subsystem: "org.k12u.Kanato", category: "ModelManager")

    /// Debug ビルドでは開発用に未確認モデルの取得を許可し、Release では確認済みのみに限定する
    static var allowsUnverifiedLicensesByDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    init(
        rootDirectory: URL,
        session: URLSession? = nil,
        allowsUnverifiedLicenses: Bool = ModelManager.allowsUnverifiedLicensesByDefault
    ) {
        self.rootDirectory = rootDirectory
        self.allowsUnverifiedLicenses = allowsUnverifiedLicenses
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Application Support/Kanato/Models（Sandbox 下ではコンテナ内）
    static func defaultRootDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return applicationSupport.appending(path: "Kanato/Models", directoryHint: .isDirectory)
    }

    static func makeDefault() throws -> ModelManager {
        ModelManager(rootDirectory: try defaultRootDirectory())
    }

    func directory(for modelID: String) throws -> URL {
        guard ModelManifest.isValidModelID(modelID) else { throw ModelStoreError.invalidModelID }
        return rootDirectory.appending(path: modelID, directoryHint: .isDirectory)
    }

    // MARK: - Listing

    /// receipt を持つ（＝検証済みで配置された）モデルの一覧
    func installedModels() -> [InstalledModel] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .compactMap { url in
                guard ModelManifest.isValidModelID(url.lastPathComponent) else { return nil }
                return installedModel(at: url)
            }
            .sorted { $0.id < $1.id }
    }

    func installedModel(id: String) -> InstalledModel? {
        guard let directory = try? directory(for: id) else { return nil }
        return installedModel(at: directory)
    }

    private func installedModel(at directory: URL) -> InstalledModel? {
        guard let receipt = Self.readReceipt(in: directory), receipt.modelID == directory.lastPathComponent else {
            return nil
        }
        return InstalledModel(
            id: receipt.modelID,
            revision: receipt.revision,
            directory: directory,
            files: receipt.files,
            installedAt: receipt.installedAt
        )
    }

    // MARK: - Status

    /// マニフェストの記載とディスク上の状態を照合する（ハッシュは計算しない。`verify` を使う）
    func installState(of model: ModelManifest.Model) -> InstallState {
        guard let installed = installedModel(id: model.id) else { return .notInstalled }
        guard installed.revision == model.source.revision, installed.files == model.files else {
            return .outdated(installedRevision: installed.revision)
        }
        let missing = missingFiles(of: model, in: installed.directory)
        return missing.isEmpty ? .installed : .incomplete(missingFiles: missing)
    }

    /// 存在しない、またはサイズがマニフェストと一致しないファイル
    func missingFiles(of model: ModelManifest.Model) -> [String] {
        guard let directory = try? directory(for: model.id) else { return model.files.map(\.path) }
        return missingFiles(of: model, in: directory)
    }

    private func missingFiles(of model: ModelManifest.Model, in directory: URL) -> [String] {
        model.files.compactMap { file in
            let url = directory.appending(path: file.path, directoryHint: .notDirectory)
            return Self.fileSize(at: url) == file.size ? nil : file.path
        }
    }

    // MARK: - Integrity

    /// 全ファイルの存在・サイズ・SHA-256 をマニフェストと照合する
    func verify(_ model: ModelManifest.Model) async throws {
        let directory = try directory(for: model.id)
        guard installedModel(at: directory) != nil else { throw ModelStoreError.notInstalled(model.id) }
        try await Self.verifyFiles(of: model, in: directory)
    }

    private static func verifyFiles(of model: ModelManifest.Model, in directory: URL) async throws {
        for file in model.files {
            try Task.checkCancellation()
            let url = directory.appending(path: file.path, directoryHint: .notDirectory)
            guard let size = fileSize(at: url) else { throw ModelStoreError.missingFile(file.path) }
            guard size == file.size else { throw ModelStoreError.sizeMismatch(file.path) }
            guard try sha256(of: url) == file.sha256 else { throw ModelStoreError.checksumMismatch(file.path) }
        }
    }

    /// 大きなファイルでもメモリに載せきらないよう、分割して SHA-256 を計算する
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download

    /// マニフェストに記載されたファイルを取得し、検証後に原子的に配置する。
    /// 既存のインストールは検証が成功した場合にのみ置き換える。
    @discardableResult
    func download(
        _ model: ModelManifest.Model,
        progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil
    ) async throws -> InstalledModel {
        guard ModelManifest.isValidModelID(model.id) else { throw ModelStoreError.invalidModelID }
        guard allowsUnverifiedLicenses || model.license.redistribution == .verified else {
            throw ModelStoreError.licenseNotVerified(model.id, model.license.redistribution)
        }
        guard activeDownloads.withLock({ $0.insert(model.id).inserted }) else {
            throw ModelStoreError.alreadyDownloading(model.id)
        }
        defer { activeDownloads.withLock { _ = $0.remove(model.id) } }

        let fileManager = FileManager.default
        let stagingRoot = rootDirectory.appending(path: Self.stagingDirectoryName, directoryHint: .isDirectory)
        let staging = stagingRoot.appending(path: "\(model.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError.fileOperationFailed
        }
        // 成功・失敗にかかわらず一時ディレクトリは残さない（成功時は移動済みで存在しない）
        defer { try? fileManager.removeItem(at: staging) }

        try checkAvailableCapacity(for: model.totalSize, at: stagingRoot)

        let start = ContinuousClock.now
        var completedBytes: Int64 = 0
        progress?(ModelDownloadProgress(completedFiles: 0, totalFiles: model.files.count, completedBytes: 0, totalBytes: model.totalSize))

        for (index, file) in model.files.enumerated() {
            try Task.checkCancellation()
            let destination = staging.appending(path: file.path, directoryHint: .notDirectory)
            try await downloadFile(file, from: model.source.downloadURL(for: file), to: destination)

            guard Self.fileSize(at: destination) == file.size else { throw ModelStoreError.sizeMismatch(file.path) }
            guard try Self.sha256(of: destination) == file.sha256 else { throw ModelStoreError.checksumMismatch(file.path) }

            completedBytes += file.size
            progress?(ModelDownloadProgress(
                completedFiles: index + 1, totalFiles: model.files.count,
                completedBytes: completedBytes, totalBytes: model.totalSize
            ))
        }

        let receipt = ModelInstallReceipt(
            schemaVersion: ModelInstallReceipt.currentSchemaVersion,
            modelID: model.id,
            revision: model.source.revision,
            files: model.files,
            installedAt: Date()
        )
        do {
            try Self.receiptEncoder.encode(receipt)
                .write(to: staging.appending(path: Self.receiptFileName), options: .atomic)
        } catch {
            throw ModelStoreError.fileOperationFailed
        }

        try Task.checkCancellation()
        let destination = try directory(for: model.id)
        try Self.place(staging, at: destination)
        Self.logger.info("Model \(model.id, privacy: .public) installed in \(ContinuousClock.now - start, privacy: .public)")

        guard let installed = installedModel(at: destination) else { throw ModelStoreError.fileOperationFailed }
        return installed
    }

    private func downloadFile(_ file: ModelManifest.File, from url: URL, to destination: URL) async throws {
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: url)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ModelStoreError.downloadFailed(file.path)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelStoreError.httpStatus(file.path, http.statusCode)
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw ModelStoreError.fileOperationFailed
        }
    }

    /// 同一ボリューム内の rename で配置する。既存があれば置換し、途中状態を最終位置に残さない
    private static func place(_ staging: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw ModelStoreError.fileOperationFailed
        }
    }

    private func checkAvailableCapacity(for requiredBytes: Int64, at url: URL) throws {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        // ダウンロード中の一時ファイルと配置先が同時に存在しうるため余裕を持たせる
        let margin: Int64 = 512 * 1024 * 1024
        if available < requiredBytes + margin {
            throw ModelStoreError.insufficientStorage(required: requiredBytes, available: available)
        }
    }

    // MARK: - Delete & Cleanup

    func delete(modelID: String) throws {
        let directory = try directory(for: modelID)
        guard !activeDownloads.withLock({ $0.contains(modelID) }) else {
            throw ModelStoreError.alreadyDownloading(modelID)
        }
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw ModelStoreError.notInstalled(modelID)
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw ModelStoreError.fileOperationFailed
        }
    }

    /// 前回の異常終了などで残った一時ディレクトリを削除する（ダウンロード中でないときに呼ぶ）
    func cleanUpStaging() {
        guard activeDownloads.withLock({ $0.isEmpty }) else { return }
        try? FileManager.default.removeItem(
            at: rootDirectory.appending(path: Self.stagingDirectoryName, directoryHint: .isDirectory)
        )
    }

    // MARK: - Storage

    /// モデル保存領域全体の使用量（バイト、一時ディレクトリを含む）
    func storageUsage() -> Int64 {
        Self.allocatedSize(of: rootDirectory)
    }

    func storageUsage(of modelID: String) -> Int64 {
        guard let directory = try? directory(for: modelID) else { return 0 }
        return Self.allocatedSize(of: directory)
    }

    private static func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Helpers

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    private static var receiptEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func readReceipt(in directory: URL) -> ModelInstallReceipt? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appending(path: receiptFileName)),
              let receipt = try? decoder.decode(ModelInstallReceipt.self, from: data),
              receipt.schemaVersion == ModelInstallReceipt.currentSchemaVersion
        else { return nil }
        return receipt
    }
}

// MARK: - Types

/// 検証済みで配置されたことを示す記録。モデルディレクトリ直下に置く
nonisolated struct ModelInstallReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var modelID: String
    var revision: String
    var files: [ModelManifest.File]
    var installedAt: Date
}

nonisolated struct InstalledModel: Equatable, Sendable, Identifiable {
    var id: String
    var revision: String
    var directory: URL
    var files: [ModelManifest.File]
    var installedAt: Date
}

nonisolated enum InstallState: Equatable, Sendable {
    case notInstalled
    case installed
    /// マニフェストのリビジョンまたはファイル一覧が更新されている
    case outdated(installedRevision: String)
    /// receipt はあるがファイルが欠けている・サイズが違う
    case incomplete(missingFiles: [String])
}

nonisolated struct ModelDownloadProgress: Equatable, Sendable {
    var completedFiles: Int
    var totalFiles: Int
    var completedBytes: Int64
    var totalBytes: Int64

    var fractionCompleted: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
    }
}

nonisolated enum ModelStoreError: LocalizedError, Equatable, Sendable {
    case invalidModelID
    case licenseNotVerified(String, ModelManifest.RedistributionStatus)
    case alreadyDownloading(String)
    case insufficientStorage(required: Int64, available: Int64)
    case downloadFailed(String)
    case httpStatus(String, Int)
    case sizeMismatch(String)
    case checksumMismatch(String)
    case missingFile(String)
    case notInstalled(String)
    case fileOperationFailed

    var errorDescription: String? {
        switch self {
        case .invalidModelID: "Model ID が不正です"
        case .licenseNotVerified(let id, let status): "\(id) は再配布可否が\(status.displayName)のため取得できません"
        case .alreadyDownloading(let id): "\(id) はダウンロード中です"
        case .insufficientStorage(let required, _):
            "空き容量が不足しています（必要: \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))）"
        case .downloadFailed(let path): "ダウンロードに失敗しました（\(path)）"
        case .httpStatus(let path, let code): "ダウンロードに失敗しました（\(path), HTTP \(code)）"
        case .sizeMismatch(let path): "ファイルサイズがマニフェストと一致しません（\(path)）"
        case .checksumMismatch(let path): "SHA-256 がマニフェストと一致しません（\(path)）"
        case .missingFile(let path): "モデルファイルがありません（\(path)）"
        case .notInstalled(let id): "\(id) はインストールされていません"
        case .fileOperationFailed: "モデルファイルの保存・削除に失敗しました"
        }
    }
}
