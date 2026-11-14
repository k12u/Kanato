//
//  LlamaCppEngine.swift
//  Kanato
//

import Foundation
import LlamaCpp

/// llama.cpp（Packages/LlamaCpp）で GGUF モデルを実行するローカル推論エンジン。
/// 生成は同期処理のため、呼び出し元のタスクのスレッドで実行される（zenz-v3.2-small で 1 回数十 ms）。
nonisolated final class LlamaCppEngine: LocalInferenceEngine, @unchecked Sendable {
    static let backendKind: ModelManifest.BackendKind = .llamaCpp
    static let supportedFormats: Set<ModelManifest.ModelFormat> = [.gguf]
    /// マニフェストにコンテキスト長がない場合の既定値
    static let defaultContextLength = 2048

    private let generator: LlamaTextGenerator

    init(model: ModelManifest.Model, directory: URL) throws {
        guard let file = model.files.first(where: { $0.path.hasSuffix(".gguf") }) else {
            throw InferenceBackendError.unsupportedModelFormat(model.format)
        }
        let path = directory.appending(path: file.path, directoryHint: .notDirectory).path(percentEncoded: false)
        do {
            generator = try LlamaTextGenerator(
                modelPath: path,
                configuration: .init(
                    contextLength: UInt32(model.contextLength ?? Self.defaultContextLength),
                    metadataOverrides: model.metadataOverrides ?? [:]
                )
            )
        } catch {
            throw InferenceBackendError.modelLoadFailed(model.id)
        }
    }

    func completeText(prompt: String, maxTokens: Int) async throws -> String {
        do {
            return try generator.generate(prompt: prompt, maxTokens: maxTokens) { !Task.isCancelled }
        } catch LlamaTextGenerator.Error.cancelled {
            throw ConversionError.cancelled
        } catch {
            throw ConversionError.invalidResponse
        }
    }
}
