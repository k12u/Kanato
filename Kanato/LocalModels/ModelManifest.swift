//
//  ModelManifest.swift
//  Kanato
//

import Foundation

/// ローカル推論用モデルの管理情報（`model-manifest.json`）。
/// 重みファイル自体は Git にもアプリにも含めず、この情報をもとに取得・検証する。
/// `scripts/download-model.sh` も同じファイルを読むため、スキーマを変更する場合は両方を更新する。
nonisolated struct ModelManifest: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let resourceName = "model-manifest"

    var schemaVersion: Int
    /// 新規ユーザーに既定で使ってもらうモデル（アプリ内推論で実行できること）
    var defaultModelID: String?
    var models: [Model]

    func model(id: String) -> Model? {
        models.first { $0.id == id }
    }

    /// 製品ビルドへ同梱してよいモデル（再配布可否が確認済みのもののみ）
    var embeddableModels: [Model] {
        models.filter { $0.license.redistribution == .verified }
    }

    // MARK: - Model

    nonisolated struct Model: Codable, Equatable, Sendable, Identifiable {
        /// 保存先ディレクトリ名にも使う。英数字と `.` `_` `-` のみ
        var id: String
        var name: String
        var source: Source
        var files: [File]
        var license: License
        var backend: BackendKind
        var format: ModelFormat
        /// 例: "Q4_K_M", "4bit"。量子化なしは "none"
        var quantization: String
        /// 推論時に必要なおおよそのメモリ量（MB）
        var estimatedMemoryMB: Int
        /// 変換に使うプロンプトの形式。nil は未定義（ローカル推論に使えない）
        var promptFormat: PromptFormat?
        /// 推論時のコンテキスト長（トークン数）。nil は既定値
        var contextLength: Int?
        /// 推論エンジンで読み込むときに上書きする GGUF メタデータ（文字列値）。
        /// 例: 公式 zenz GGUF の tokenizer.ggml.pre は上流の llama.cpp が認識しないため "gpt-2" にする
        var metadataOverrides: [String: String]?

        var totalSize: Int64 {
            files.reduce(0) { $0 + $1.size }
        }
    }

    nonisolated struct Source: Codable, Equatable, Sendable {
        /// 配布元リポジトリのページ（例: https://huggingface.co/org/repo）
        var repositoryURL: URL
        /// 固定するリビジョン（コミットハッシュ）。ブランチ名は使わない
        var revision: String
        /// 各ファイルの取得元 = downloadBaseURL + "/" + File.path。revision を含むこと
        /// （例: https://huggingface.co/org/repo/resolve/<revision>）
        var downloadBaseURL: URL

        func downloadURL(for file: File) -> URL {
            downloadBaseURL.appending(path: file.path, directoryHint: .notDirectory)
        }
    }

    nonisolated struct File: Codable, Equatable, Sendable {
        /// モデルディレクトリからの相対パス
        var path: String
        /// 小文字 16 進 64 桁
        var sha256: String
        /// バイト数
        var size: Int64
    }

    nonisolated struct License: Codable, Equatable, Sendable {
        /// SPDX 識別子（例: "Apache-2.0"）。独自ライセンスは "LicenseRef-<名前>"
        var identifier: String
        /// ライセンス文書のパス。`files` に含め、モデルと一緒に取得・検証する
        var documentPath: String
        /// アプリに同梱して再配布してよいかの確認状態（Embedded 用）
        var redistribution: RedistributionStatus
        /// ユーザーが配布元から直接ダウンロードして使うことの確認状態（Download 用）。
        /// アプリはモデルを再配布しないが、ライセンス条件（帰属表示など）を満たしているかを確認する。省略時は未確認
        var downloadUse: RedistributionStatus?
        /// 帰属表示（作者・著作権者・基盤モデルなど）。設定画面とサードパーティ表示に出す
        var attribution: String?
        /// ライセンス本文の URL（例: https://creativecommons.org/licenses/by-sa/4.0/）
        var url: URL?
        /// 確認者・確認日・根拠など
        var notes: String?

        var downloadUseStatus: RedistributionStatus {
            downloadUse ?? .unverified
        }
    }

    /// ライセンス条件の確認状態
    nonisolated enum RedistributionStatus: String, Codable, Sendable, CaseIterable {
        /// 未確認。製品ビルドへ同梱しない
        case unverified
        /// 確認中。製品ビルドへ同梱しない
        case inReview = "in-review"
        /// 確認済み。Embedded の候補にできる
        case verified

        var displayName: String {
            switch self {
            case .unverified: "未確認"
            case .inReview: "確認中"
            case .verified: "確認済み"
            }
        }
    }

    /// モデルへの入力（プロンプト）の形式
    nonisolated enum PromptFormat: String, Codable, Sendable, CaseIterable {
        /// zenz v2 系: U+EE00 入力 [U+EE02 左文脈] U+EE01
        case zenzV2 = "zenz-v2"
        /// zenz v3 系: [U+EE02 左文脈] U+EE00 入力 U+EE01
        case zenzV3 = "zenz-v3"
        /// 汎用 LLM（チャット形式 + システムプロンプト）
        case chat
    }

    /// 推論バックエンド種別（候補）
    nonisolated enum BackendKind: String, Codable, Sendable, CaseIterable {
        case mlx
        case llamaCpp = "llama.cpp"

        var displayName: String {
            switch self {
            case .mlx: "MLX Swift"
            case .llamaCpp: "llama.cpp"
            }
        }
    }

    /// モデル形式
    nonisolated enum ModelFormat: String, Codable, Sendable, CaseIterable {
        /// MLX 形式（safetensors + config.json / tokenizer）
        case mlx
        /// llama.cpp 用の単一ファイル
        case gguf
        /// Hugging Face Transformers 形式（safetensors + config / tokenizer）。
        /// 推論エンジンで使うには変換が必要（例: llama.cpp の convert_hf_to_gguf.py で GGUF へ）
        case safetensors
    }
}

// MARK: - Loading & Validation

nonisolated enum ModelManifestError: LocalizedError, Equatable, Sendable {
    case notFound
    case unreadable
    case unsupportedSchemaVersion(Int)
    case invalid(modelID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notFound: "モデルマニフェストが見つかりません"
        case .unreadable: "モデルマニフェストを読み込めません"
        case .unsupportedSchemaVersion(let version): "未対応のモデルマニフェストです（schemaVersion \(version)）"
        case .invalid(let id, let reason): "モデルマニフェストの記述が不正です（\(id): \(reason)）"
        }
    }
}

nonisolated extension ModelManifest {
    /// アプリに同梱したマニフェスト（メタデータのみ。重みは含まない）
    static func loadBundled(from bundle: Bundle = .main) throws -> ModelManifest {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw ModelManifestError.notFound
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> ModelManifest {
        guard let data = try? Data(contentsOf: url) else { throw ModelManifestError.unreadable }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> ModelManifest {
        guard let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else {
            throw ModelManifestError.unreadable
        }
        try manifest.validate()
        return manifest
    }

    /// ダウンロード・保存の前提となる制約を検証する。パスの逸脱やリビジョン未固定を防ぐ
    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw ModelManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        if let defaultModelID, model(id: defaultModelID) == nil {
            throw ModelManifestError.invalid(modelID: defaultModelID, reason: "既定のモデルがマニフェストにありません")
        }
        var seenIDs = Set<String>()
        for model in models {
            func invalid(_ reason: String) -> ModelManifestError {
                .invalid(modelID: model.id, reason: reason)
            }
            guard Self.isValidModelID(model.id) else { throw invalid("Model ID に使えない文字があります") }
            guard seenIDs.insert(model.id).inserted else { throw invalid("Model ID が重複しています") }
            guard !model.files.isEmpty else { throw invalid("ファイル一覧が空です") }

            let revision = model.source.revision
            guard !revision.isEmpty, revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw invalid("revision はコミットハッシュで指定してください")
            }
            guard model.source.downloadBaseURL.scheme == "https" else { throw invalid("downloadBaseURL は HTTPS にしてください") }
            guard model.source.downloadBaseURL.absoluteString.contains(revision) else {
                throw invalid("downloadBaseURL に revision が含まれていません")
            }

            var seenPaths = Set<String>()
            for file in model.files {
                guard Self.isSafeRelativePath(file.path) else { throw invalid("不正なファイルパス: \(file.path)") }
                guard seenPaths.insert(file.path).inserted else { throw invalid("ファイルが重複しています: \(file.path)") }
                guard Self.isValidSHA256(file.sha256) else { throw invalid("SHA-256 が不正です: \(file.path)") }
                guard file.size > 0 else { throw invalid("サイズが不正です: \(file.path)") }
            }
            guard !model.license.identifier.isEmpty else { throw invalid("ライセンス識別子がありません") }
            guard seenPaths.contains(model.license.documentPath) else {
                throw invalid("ライセンス文書がファイル一覧に含まれていません")
            }
            guard model.estimatedMemoryMB > 0 else { throw invalid("必要メモリが不正です") }
            if let contextLength = model.contextLength, !(64...131_072).contains(contextLength) {
                throw invalid("コンテキスト長が不正です")
            }
            for (key, value) in model.metadataOverrides ?? [:] {
                // llama.cpp の kv override は キー・値とも 127 バイトまで
                guard !key.isEmpty, key.utf8.count < 128, value.utf8.count < 128 else {
                    throw invalid("メタデータの上書き指定が不正です: \(key)")
                }
            }
        }
    }

    static func isValidModelID(_ id: String) -> Bool {
        guard let first = id.first, first != ".", id.count <= 128 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// 絶対パス・`..`・空要素・隠しファイルを含まない相対パス
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    static func isValidSHA256(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
