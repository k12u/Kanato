//
//  MockLLMServerTests.swift
//  DevServerTests
//

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import DevServer

struct MockLLMServerTests {

    private func makeApp(mode: MockMode = .normal, delayMilliseconds: Int = 0) -> some ApplicationProtocol {
        MockLLMServer(configuration: ServerConfiguration(mode: mode, delayMilliseconds: delayMilliseconds))
            .buildApplication()
    }

    private func chatBody(
        model: String = "kanafilter-mock",
        user: String = "きょうはいいてんきです",
        stream: Bool? = nil
    ) throws -> ByteBuffer {
        var object: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "かな漢字変換を実行してください"],
                ["role": "user", "content": user],
            ],
            "temperature": 0,
        ]
        if let stream { object["stream"] = stream }
        return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: object))
    }

    private func jsonObject(_ response: TestResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
    }

    private func content(_ response: TestResponse) throws -> String? {
        let choices = try #require(try jsonObject(response)["choices"] as? [[String: Any]])
        let message = try #require(choices.first?["message"] as? [String: Any])
        return message["content"] as? String
    }

    private func errorMessage(_ response: TestResponse) throws -> String {
        let error = try #require(try jsonObject(response)["error"] as? [String: Any])
        return try #require(error["message"] as? String)
    }

    private func postChat(_ body: ByteBuffer, app: some ApplicationProtocol) async throws -> TestResponse {
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json"], body: body
            )
        }
    }

    // MARK: - Endpoints

    @Test func healthReturnsOK() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                let json = try jsonObject(response)
                #expect(json["status"] as? String == "ok")
                #expect(json["service"] as? String == "KanaFilter DevServer")
            }
        }
    }

    @Test func modelsReturnsModelList() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .ok)
                let json = try jsonObject(response)
                #expect(json["object"] as? String == "list")
                let data = try #require(json["data"] as? [[String: Any]])
                #expect(data.count == 1)
                #expect(data[0]["id"] as? String == "kanafilter-mock")
                #expect(data[0]["object"] as? String == "model")
                #expect(data[0]["owned_by"] as? String == "kanafilter")
            }
        }
    }

    @Test func chatCompletionReturnsOpenAICompatibleResponse() async throws {
        let response = try await postChat(try chatBody(), app: makeApp())
        #expect(response.status == .ok)
        #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
        let json = try jsonObject(response)
        #expect(json["object"] as? String == "chat.completion")
        #expect(json["model"] as? String == "kanafilter-mock")
        let choices = try #require(json["choices"] as? [[String: Any]])
        #expect(choices.count == 1)
        #expect(choices[0]["finish_reason"] as? String == "stop")
        let message = try #require(choices[0]["message"] as? [String: Any])
        #expect(message["role"] as? String == "assistant")
        #expect(message["content"] as? String == "今日はいい天気です")
    }

    @Test(arguments: MockConversionEngine.defaultMappings.sorted { $0.key < $1.key })
    func appliesFixedMapping(input: String, expected: String) async throws {
        let response = try await postChat(try chatBody(user: input), app: makeApp())
        #expect(response.status == .ok)
        #expect(try content(response) == expected)
    }

    @Test func returnsUnregisteredTextAsIs() async throws {
        let input = "とうろくされていないぶんしょう"
        let response = try await postChat(try chatBody(user: input), app: makeApp())
        #expect(response.status == .ok)
        #expect(try content(response) == input)
    }

    @Test func usesLastUserMessage() async throws {
        let body = ByteBuffer(string: """
            {"model":"kanafilter-mock","messages":[
              {"role":"user","content":"てすと"},
              {"role":"assistant","content":"テスト"},
              {"role":"user","content":"らいしゅうのかいぎでかくにんする"}
            ]}
            """)
        let response = try await postChat(body, app: makeApp())
        #expect(try content(response) == "来週の会議で確認する")
    }

    // MARK: - Validation errors

    @Test func rejectsEmptyMessages() async throws {
        let body = ByteBuffer(string: #"{"model":"kanafilter-mock","messages":[]}"#)
        let response = try await postChat(body, app: makeApp())
        #expect(response.status == .badRequest)
        #expect(try errorMessage(response).contains("messages"))
    }

    @Test func rejectsMessagesWithoutUser() async throws {
        let body = ByteBuffer(string: #"{"model":"kanafilter-mock","messages":[{"role":"system","content":"x"}]}"#)
        let response = try await postChat(body, app: makeApp())
        #expect(response.status == .badRequest)
    }

    @Test func rejectsUnknownModel() async throws {
        let response = try await postChat(try chatBody(model: "gpt-4o"), app: makeApp())
        #expect(response.status == .badRequest)
        let error = try #require(try jsonObject(response)["error"] as? [String: Any])
        #expect(error["code"] as? String == "model_not_found")
    }

    @Test func rejectsStreaming() async throws {
        let response = try await postChat(try chatBody(stream: true), app: makeApp())
        #expect(response.status == .badRequest)
        #expect(try errorMessage(response).contains("stream"))
    }

    @Test func acceptsStreamFalse() async throws {
        let response = try await postChat(try chatBody(stream: false), app: makeApp())
        #expect(response.status == .ok)
    }

    @Test func rejectsMalformedRequestBody() async throws {
        let response = try await postChat(ByteBuffer(string: "not json"), app: makeApp())
        #expect(response.status == .badRequest)
    }

    // MARK: - Failure simulation

    @Test func appliesConfiguredDelay() async throws {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            let response = try await postChat(try chatBody(), app: makeApp(delayMilliseconds: 300))
            #expect(response.status == .ok)
        }
        #expect(elapsed >= .milliseconds(300))
    }

    @Test func noDelayByDefault() async throws {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await postChat(try chatBody(), app: makeApp())
        }
        #expect(elapsed < .milliseconds(300))
    }

    @Test func simulatesHTTP500() async throws {
        let response = try await postChat(try chatBody(), app: makeApp(mode: .http500))
        #expect(response.status == .internalServerError)
        #expect(try errorMessage(response).isEmpty == false)
    }

    @Test func simulatesEmptyChoices() async throws {
        let response = try await postChat(try chatBody(), app: makeApp(mode: .emptyChoices))
        #expect(response.status == .ok)
        let choices = try #require(try jsonObject(response)["choices"] as? [Any])
        #expect(choices.isEmpty)
    }

    @Test func simulatesEmptyContent() async throws {
        let response = try await postChat(try chatBody(), app: makeApp(mode: .emptyContent))
        #expect(response.status == .ok)
        #expect(try content(response) == "")
    }

    @Test func simulatesInvalidJSON() async throws {
        let response = try await postChat(try chatBody(), app: makeApp(mode: .invalidJSON))
        #expect(response.status == .ok)
        #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
        #expect((try? JSONSerialization.jsonObject(with: Data(buffer: response.body))) == nil)
    }

    @Test func failureModesDoNotAffectHealth() async throws {
        try await makeApp(mode: .http500).test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// 実際にソケットで待ち受けた状態での疎通（.live）
    @Test func servesOverRealSocket() async throws {
        let app = MockLLMServer(configuration: ServerConfiguration(port: 0)).buildApplication()
        try await app.test(.live) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }
}

struct ServerConfigurationTests {

    @Test func usesDefaults() throws {
        let configuration = try ServerConfiguration.fromEnvironment([:])
        #expect(configuration.host == "127.0.0.1")
        #expect(configuration.port == 8765)
        #expect(configuration.mode == .normal)
        #expect(configuration.delayMilliseconds == 0)
        #expect(configuration.isLoopback)
    }

    @Test func readsEnvironment() throws {
        let configuration = try ServerConfiguration.fromEnvironment([
            "KANAFILTER_MOCK_PORT": "9000",
            "KANAFILTER_MOCK_MODE": "empty_choices",
            "KANAFILTER_MOCK_DELAY_MS": "1500",
        ])
        #expect(configuration.port == 9000)
        #expect(configuration.mode == .emptyChoices)
        #expect(configuration.delay == .milliseconds(1500))
    }

    @Test(arguments: MockMode.allCases)
    func acceptsAllModeNames(mode: MockMode) throws {
        let configuration = try ServerConfiguration.fromEnvironment(["KANAFILTER_MOCK_MODE": mode.rawValue])
        #expect(configuration.mode == mode)
    }

    @Test(arguments: [
        ["KANAFILTER_MOCK_PORT": "0"],
        ["KANAFILTER_MOCK_PORT": "abc"],
        ["KANAFILTER_MOCK_MODE": "timeout"],
        ["KANAFILTER_MOCK_DELAY_MS": "-1"],
    ])
    func rejectsInvalidValues(environment: [String: String]) {
        #expect(throws: ServerConfiguration.InvalidValue.self) {
            try ServerConfiguration.fromEnvironment(environment)
        }
    }
}

struct MockConversionEngineTests {

    @Test func trimsSurroundingWhitespaceForLookup() {
        #expect(MockConversionEngine().convert("  てすと\n") == "テスト")
    }

    @Test func extractsLastUserMessage() {
        let messages: [ChatCompletionRequest.Message] = [
            .init(role: "system", content: "s"),
            .init(role: "user", content: "a"),
            .init(role: "assistant", content: "b"),
            .init(role: "user", content: "c"),
        ]
        #expect(MockConversionEngine.extractInput(from: messages) == "c")
        #expect(MockConversionEngine.extractInput(from: [.init(role: "system", content: "s")]) == nil)
    }
}
