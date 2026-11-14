//
//  LlamaTextGeneratorTests.swift
//  LlamaCppTests
//
//  実モデルを使う結合テスト。環境変数 KANATO_TEST_ZENZ_GGUF に zenz v3 系の GGUF のパスを指定したときだけ実行する。
//    KANATO_TEST_ZENZ_GGUF=$PWD/../../.models/zenz-v3.2-small/ggml-model-Q5_K_M.gguf swift test
//

import Foundation
import Testing
@testable import LlamaCpp

struct LlamaTextGeneratorTests {
    static let modelPath = ProcessInfo.processInfo.environment["KANATO_TEST_ZENZ_GGUF"]

    private func makeGenerator() throws -> LlamaTextGenerator {
        try LlamaTextGenerator(
            modelPath: try #require(Self.modelPath),
            configuration: .init(contextLength: 1024, metadataOverrides: ["tokenizer.ggml.pre": "gpt-2"])
        )
    }

    @Test(.enabled(if: modelPath != nil))
    func convertsWithZenzV3Prompt() throws {
        let generator = try makeGenerator()
        #expect(try generator.generate(prompt: "\u{EE00}キョウハイイテンキデス\u{EE01}", maxTokens: 32) == "今日はいい天気です")
        // 呼び出し間で状態を持ち越さない
        #expect(try generator.generate(prompt: "\u{EE00}テスト\u{EE01}", maxTokens: 16) == "テスト")
        #expect(try generator.generate(prompt: "\u{EE02}Apple\u{EE00}モ、アプリヲツカウ\u{EE01}", maxTokens: 32) == "も、アプリを使う")
    }

    @Test(.enabled(if: modelPath != nil))
    func stopsWhenCancelled() throws {
        let generator = try makeGenerator()
        #expect(throws: LlamaTextGenerator.Error.cancelled) {
            try generator.generate(prompt: "\u{EE00}テスト\u{EE01}", maxTokens: 16, shouldContinue: { false })
        }
    }

    @Test(.enabled(if: modelPath != nil))
    func rejectsTooLongPrompt() throws {
        let generator = try makeGenerator()
        let prompt = String(repeating: "ア", count: 1100)
        #expect(throws: LlamaTextGenerator.Error.self) {
            try generator.generate(prompt: prompt, maxTokens: 16)
        }
    }

    @Test func missingModelFailsToLoad() {
        #expect(throws: LlamaTextGenerator.Error.modelLoadFailed) {
            try LlamaTextGenerator(modelPath: "/nonexistent/model.gguf")
        }
    }
}
