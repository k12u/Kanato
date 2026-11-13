//
//  ConversionServiceTests.swift
//  KanatoTests
//

import Foundation
import Testing
@testable import Kanato

/// 応答を差し替えられる LLM クライアントのモック
nonisolated final class MockChatClient: ChatCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (String) throws -> String
    private var receivedInputs: [String] = []

    init(handler: @escaping @Sendable (String) throws -> String) {
        self.handler = handler
    }

    var inputs: [String] { lock.withLock { receivedInputs } }

    func complete(system: String, user: String) async throws -> String {
        lock.withLock { receivedInputs.append(user) }
        return try handler(user)
    }
}

struct ConversionServiceTests {

    @Test func convertsText() async throws {
        let client = MockChatClient { _ in "今日の会議で決定した仕様を来週までに実装する" }
        let service = ConversionService(client: client)
        let result = try await service.convert(text: "きょうのかいぎでけっていしたしようをらいしゅうまでにじっそうする")
        #expect(result == "今日の会議で決定した仕様を来週までに実装する")
        #expect(client.inputs == ["きょうのかいぎでけっていしたしようをらいしゅうまでにじっそうする"])
    }

    @Test(arguments: ["", "  ", "\n"])
    func rejectsEmptyInputWithoutCallingLLM(input: String) async {
        let client = MockChatClient { _ in "x" }
        await #expect(throws: ConversionError.emptyInput) {
            try await ConversionService(client: client).convert(text: input)
        }
        #expect(client.inputs.isEmpty)
    }

    @Test func rejectsTooLongInput() async {
        let client = MockChatClient { _ in "x" }
        let input = String(repeating: "あ", count: ConversionService.maxInputLength + 1)
        await #expect(throws: ConversionError.inputTooLong(limit: ConversionService.maxInputLength)) {
            try await ConversionService(client: client).convert(text: input)
        }
        #expect(client.inputs.isEmpty)
    }

    @Test func rejectsEmptyResponse() async {
        let service = ConversionService(client: MockChatClient { _ in "  \n" })
        await #expect(throws: ConversionError.emptyResult) {
            try await service.convert(text: "きょう")
        }
    }

    @Test func rejectsCodeFencedResponse() async {
        let service = ConversionService(client: MockChatClient { _ in "```\n今日\n```" })
        await #expect(throws: ConversionError.unexpectedFormat("コードフェンス")) {
            try await service.convert(text: "きょう")
        }
    }

    @Test func propagatesClientError() async {
        let service = ConversionService(client: MockChatClient { _ in throw ConversionError.timeout })
        await #expect(throws: ConversionError.timeout) {
            try await service.convert(text: "きょう")
        }
    }

    @Test func handlesMultilineText() async throws {
        let service = ConversionService(client: MockChatClient { _ in "今日は晴れ\n明日は雨" })
        let result = try await service.convert(text: "きょうははれ\nあしたはあめ\n")
        #expect(result == "今日は晴れ\n明日は雨\n")
    }

    @Test func sendsTrimmedBodyButKeepsSurroundingWhitespace() async throws {
        let client = MockChatClient { _ in "今日" }
        let result = try await ConversionService(client: client).convert(text: " きょう ")
        #expect(client.inputs == ["きょう"])
        #expect(result == " 今日 ")
    }

    @Test func handlesMixedAlphanumerics() async throws {
        let service = ConversionService(client: MockChatClient { _ in "Python 3.12で実装する" })
        #expect(try await service.convert(text: "ぱいそん 3.12でじっそうする") == "Python 3.12で実装する")
    }

    @Test func handlesURLAndCodeInInput() async throws {
        let output = "詳細はhttps://example.com/docs?id=1を参照し、`let x = 1`を実行する"
        let service = ConversionService(client: MockChatClient { _ in output })
        let result = try await service.convert(text: "しょうさいはhttps://example.com/docs?id=1をさんしょうし、`let x = 1`をじっこうする")
        #expect(result == output)
    }
}
