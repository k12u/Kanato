//
//  ZenzBackendTests.swift
//  KanatoTests
//

import Foundation
import Testing
@testable import Kanato

struct ZenzBackendTests {
    /// プロンプトを記録し、カタカナ入力に対応する出力を返すモック
    private final class MockCompletionClient: TextCompletionClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        let respond: @Sendable (String) -> String

        init(respond: @escaping @Sendable (String) -> String) {
            self.respond = respond
        }

        var prompts: [String] { lock.withLock { _prompts } }

        func completeText(prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { _prompts.append(prompt) }
            return respond(prompt)
        }
    }

    /// プロンプトからカタカナ入力部分を取り出す（文脈タグ以降は除く）
    private static func input(of prompt: String) -> String {
        let body = prompt.dropFirst().dropLast()
        return String(body.split(separator: "\u{EE02}", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    private static let dictionary = [
        "キョウハイイテンキデス": "今日はいい天気です",
        "テスト": "テスト",
        "オハヨウゴザイマス。": "おはようございます。",
        "ホンジツハヨロシクオネガイシマス。": "本日はよろしくお願いします。",
        "イカノトオリデス": "以下の通りです",
    ]

    private func makeBackend(_ respond: @escaping @Sendable (String) -> String = { Self.dictionary[Self.input(of: $0)] ?? Self.input(of: $0) })
        -> (ZenzBackend, MockCompletionClient) {
        let client = MockCompletionClient(respond: respond)
        return (ZenzBackend(client: client), client)
    }

    @Test func buildsZenzPromptWithKatakana() async throws {
        let (backend, client) = makeBackend()
        #expect(try await backend.convert("きょうはいいてんきです") == "今日はいい天気です")
        #expect(client.prompts == ["\u{EE00}キョウハイイテンキデス\u{EE01}"])
    }

    @Test func convertsHiraganaToKatakana() {
        #expect(ZenzBackend.katakana(from: "ぁゖゝゞー、ABC漢字カナ") == "ァヶヽヾー、ABC漢字カナ")
    }

    @Test func convertsEachLineAndKeepsLayout() async throws {
        let (backend, client) = makeBackend()
        let result = try await backend.convert("  おはようございます。\r\n\nほんじつはよろしくおねがいします。\n")
        #expect(result == "  おはようございます。\r\n\n本日はよろしくお願いします。\n")
        #expect(client.prompts.count == 2)
    }

    /// 「以下」で始まる正当な変換結果を説明文として拒否しない
    @Test func allowsExplanationLikeOutput() async throws {
        let (backend, _) = makeBackend()
        #expect(try await backend.convert("いかのとおりです") == "以下の通りです")
    }

    @Test func splitsLongLinesAtSentenceEnds() {
        let sentence = String(repeating: "あ", count: 90) + "。"
        let chunks = ZenzBackend.chunks(of: sentence + sentence + sentence, limit: 200)
        #expect(chunks == [sentence + sentence, sentence])

        let noBoundary = String(repeating: "あ", count: 450)
        #expect(ZenzBackend.chunks(of: noBoundary, limit: 200).map(\.count) == [200, 200, 50])

        let clauses = String(repeating: "い", count: 150) + "、" + String(repeating: "う", count: 100)
        #expect(ZenzBackend.chunks(of: clauses, limit: 200).map(\.count) == [151, 100])
    }

    @Test func convertsLongLineInChunks() async throws {
        let (backend, client) = makeBackend()
        let sentence = String(repeating: "て", count: 150) + "。"
        let result = try await backend.convert(sentence + sentence)
        #expect(client.prompts.count == 2)
        #expect(result == ZenzBackend.katakana(from: sentence + sentence))
    }

    @Test func rejectsInvalidOutputs() async {
        await #expect(throws: ConversionError.emptyResult) {
            try await makeBackend { _ in "  " }.0.convert("てすと")
        }
        await #expect(throws: ConversionError.unexpectedFormat("制御タグ")) {
            try await makeBackend { _ in "テスト\u{EE01}テスト" }.0.convert("てすと")
        }
        await #expect(throws: ConversionError.outputTooLong) {
            try await makeBackend { _ in String(repeating: "長", count: 100) }.0.convert("てすと")
        }
    }

    @Test func rejectsInvalidInputsWithoutCallingModel() async {
        let (backend, client) = makeBackend()
        await #expect(throws: ConversionError.emptyInput) { try await backend.convert(" \n ") }
        await #expect(throws: ConversionError.inputTooLong(limit: ConversionService.maxInputLength)) {
            try await backend.convert(String(repeating: "あ", count: ConversionService.maxInputLength + 1))
        }
        await #expect(throws: ConversionError.unexpectedFormat("入力に制御文字")) {
            try await backend.convert("\u{EE00}てすと")
        }
        #expect(client.prompts.isEmpty)
    }

    @Test func buildsPromptWithLeftContext() {
        #expect(ZenzBackend.prompt(for: "も", leftContext: "Apple") == "\u{EE00}モ\u{EE02}Apple\u{EE01}")
        #expect(ZenzBackend.prompt(for: "も", leftContext: "") == "\u{EE00}モ\u{EE01}")
    }

    @Test func segmentsASCIIWords() {
        typealias S = ZenzBackend.Segment
        #expect(ZenzBackend.segments(of: "Appleも、あぷり") == [S.passthrough("Apple"), .convert("も、あぷり")])
        #expect(ZenzBackend.segments(of: "Apple Developer Documentation") == [S.passthrough("Apple Developer Documentation")])
        #expect(ZenzBackend.segments(of: "これはiPhone 15です") == [S.convert("これは"), .passthrough("iPhone 15"), .convert("です")])
        // 英字を含まない ASCII はかなと一緒に変換する
        #expect(ZenzBackend.segments(of: "ごご3じから") == [S.convert("ごご3じから")])
        // ひらがなを含まない部分は変換しない
        #expect(ZenzBackend.segments(of: "「Swift」、テスト") == [S.passthrough("「Swift」、テスト")])
    }

    /// ASCII の英単語はモデルに渡さず、後続のかなには変換済みの左文脈を付ける
    @Test func passesThroughASCIIWithContext() async throws {
        let (backend, client) = makeBackend { prompt in
            Self.input(of: prompt) == "モ、アプリヲツカウ" ? "も、アプリを使う" : "?"
        }
        let result = try await backend.convert("Appleも、あぷりをつかう\nApple Developer Documentation")
        #expect(result == "Appleも、アプリを使う\nApple Developer Documentation")
        #expect(client.prompts == ["\u{EE00}モ、アプリヲツカウ\u{EE02}Apple\u{EE01}"])
    }

    @Test func factorySelectsZenzForExternalFormat() async throws {
        let client = MockCompletionClient { _ in "テスト" }
        var factory = InferenceBackendFactory()
        factory.makeTextClient = { _ in client }
        let configuration = LLMConfiguration(
            baseURL: "http://127.0.0.1:8801/v1", model: "", apiKey: nil,
            timeout: 2, temperature: 0, allowLocalNetworkHTTP: false
        )
        let backend = factory.makeBackend(
            selection: BackendSelection(mode: .external, localModelID: "", externalFormat: .zenz),
            configuration: configuration
        )
        #expect(backend is ZenzBackend)
        #expect(try await backend.convert("てすと") == "テスト")
    }
}
