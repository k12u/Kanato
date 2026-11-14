//
//  LlamaTextGenerator.swift
//  LlamaCpp
//

import Foundation
import llama

/// llama.cpp で GGUF モデルを読み込み、プロンプトの続きを貪欲法（temperature 0 相当）で生成する。
///
/// - llama_context はスレッドセーフではないため、生成はロックで直列化する
/// - 生成のたびに KV キャッシュを消去し、呼び出し間で状態を持ち越さない
/// - llama.cpp のログは既定で抑制する（プロンプト本文をログに残さないため）
public final class LlamaTextGenerator: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// コンテキスト長（トークン数）。0 ならモデルの学習時の値
        public var contextLength: UInt32
        /// GGUF メタデータの文字列値を上書きする（例: "tokenizer.ggml.pre": "gpt-2"）
        public var metadataOverrides: [String: String]
        /// GPU（Metal）に載せるレイヤー数。負の値はすべて
        public var gpuLayers: Int32

        public init(contextLength: UInt32 = 2048, metadataOverrides: [String: String] = [:], gpuLayers: Int32 = -1) {
            self.contextLength = contextLength
            self.metadataOverrides = metadataOverrides
            self.gpuLayers = gpuLayers
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidOverride(String)
        case modelLoadFailed
        case contextCreationFailed
        case tokenizationFailed
        case promptTooLong(tokens: Int, limit: Int)
        case decodeFailed(Int32)
        case cancelled
    }

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let lock = NSLock()
    public let contextLength: Int

    private static let backendInitialization: Void = {
        llama_log_set({ level, _, _ in
            // 警告以下は捨てる。エラーも本文を含みうるため出力しない
            _ = level
        }, nil)
        llama_backend_init()
    }()

    public init(modelPath: String, configuration: Configuration = Configuration()) throws {
        _ = Self.backendInitialization

        // kv_overrides は key が空の要素で終端する配列
        var overrides: [llama_model_kv_override] = []
        for (key, value) in configuration.metadataOverrides.sorted(by: { $0.key < $1.key }) {
            guard key.utf8.count < 128, value.utf8.count < 128 else { throw Error.invalidOverride(key) }
            var item = llama_model_kv_override()
            item.tag = LLAMA_KV_OVERRIDE_TYPE_STR
            Self.copy(key, into: &item.key)
            Self.copy(value, into: &item.val_str)
            overrides.append(item)
        }
        overrides.append(llama_model_kv_override())

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = configuration.gpuLayers
        let loaded: OpaquePointer? = overrides.withUnsafeBufferPointer { buffer in
            modelParams.kv_overrides = configuration.metadataOverrides.isEmpty ? nil : buffer.baseAddress
            return llama_model_load_from_file(modelPath, modelParams)
        }
        guard let model = loaded else { throw Error.modelLoadFailed }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = configuration.contextLength
        contextParams.n_batch = max(configuration.contextLength, 512)
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw Error.contextCreationFailed
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextLength = Int(llama_n_ctx(context))
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// プロンプトに続くテキストを生成する。EOS（end-of-generation）または maxTokens で終了する。
    /// - Parameter shouldContinue: トークンごとに呼ばれ、false を返すと `cancelled` を投げる
    public func generate(
        prompt: String,
        maxTokens: Int,
        shouldContinue: () -> Bool = { true }
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        llama_memory_clear(llama_get_memory(context), true)

        var tokens = try tokenize(prompt)
        let limit = contextLength - maxTokens
        guard tokens.count <= limit else { throw Error.promptTooLong(tokens: tokens.count, limit: max(limit, 0)) }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw Error.decodeFailed(status) }

        var output = Data()
        for _ in 0..<maxTokens {
            guard shouldContinue() else { throw Error.cancelled }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output.append(piece(for: token))
            status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw Error.decodeFailed(status) }
        }
        // トークン境界で UTF-8 が分割されることがあるため、最後にまとめて復号する
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - Helpers

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        // zenz の制御タグ（U+EE00 など）は通常の文字として語彙に含まれるため parse_special は不要
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, false)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, false)
        }
        guard count >= 0 else { throw Error.tokenizationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token) -> Data {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard length > 0 else { return Data() }
        return buffer.prefix(Int(length)).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 固定長の C 文字配列（タプル）へ NUL 終端付きでコピーする
    private static func copy<T>(_ string: String, into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            let bytes = Array(string.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
        }
    }
}
