//
//  OpenAICompatibleClientTests.swift
//  KanatoTests
//

import Foundation
import Testing
@testable import Kanato

/// URLSession の通信を差し替える URLProtocol スタブ
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
    }

    nonisolated(unsafe) static var reply: Reply = .response(status: 200, body: Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)

        switch Self.reply {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite(.serialized)
struct OpenAICompatibleClientTests {

    private func makeClient(
        baseURL: String = "http://localhost:1234/v1",
        model: String = "test-model",
        apiKey: String? = nil,
        temperature: Double? = 0
    ) -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let configuration = LLMConfiguration(
            baseURL: baseURL, model: model, apiKey: apiKey, timeout: 8,
            temperature: temperature, allowLocalNetworkHTTP: false
        )
        return OpenAICompatibleClient(configuration: configuration, session: URLSession(configuration: config))
    }

    private func replyJSON(_ json: String, status: Int = 200) {
        StubURLProtocol.reply = .response(status: status, body: Data(json.utf8))
    }

    private func sentBody() throws -> [String: Any] {
        let data = try #require(StubURLProtocol.lastBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Success

    @Test func returnsMessageContent() async throws {
        replyJSON(#"{"choices":[{"message":{"role":"assistant","content":"今日はいい天気です"}}]}"#)
        let result = try await makeClient().complete(system: "sys", user: "きょうはいいてんきです")
        #expect(result == "今日はいい天気です")
    }

    @Test func sendsOpenAICompatibleRequest() async throws {
        replyJSON(#"{"choices":[{"message":{"content":"x"}}]}"#)
        _ = try await makeClient(apiKey: "secret").complete(system: "sys", user: "きょう")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try sentBody()
        #expect(body["model"] as? String == "test-model")
        #expect(body["stream"] as? Bool == false)
        #expect(body["temperature"] as? Double == 0)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "sys"], ["role": "user", "content": "きょう"]])
    }

    @Test func omitsTemperatureAndAuthorizationWhenNotConfigured() async throws {
        replyJSON(#"{"choices":[{"message":{"content":"x"}}]}"#)
        _ = try await makeClient(apiKey: nil, temperature: nil).complete(system: "sys", user: "きょう")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try sentBody()["temperature"] == nil)
    }

    // MARK: - Errors

    @Test(arguments: [400, 401, 500])
    func mapsHTTPErrors(status: Int) async {
        replyJSON(#"{"error":{"message":"bad"}}"#, status: status)
        await #expect(throws: ConversionError.httpStatus(status)) {
            try await makeClient().complete(system: "sys", user: "きょう")
        }
    }

    @Test func mapsConnectionFailure() async {
        StubURLProtocol.reply = .failure(.cannotConnectToHost)
        await #expect(throws: ConversionError.cannotConnect) {
            try await makeClient().complete(system: "sys", user: "きょう")
        }
    }

    @Test func mapsTimeout() async {
        StubURLProtocol.reply = .failure(.timedOut)
        await #expect(throws: ConversionError.timeout) {
            try await makeClient().complete(system: "sys", user: "きょう")
        }
    }

    @Test func rejectsInvalidJSON() async {
        replyJSON("not json")
        await #expect(throws: ConversionError.invalidResponse) {
            try await makeClient().complete(system: "sys", user: "きょう")
        }
    }

    @Test func rejectsEmptyChoices() async {
        replyJSON(#"{"choices":[]}"#)
        await #expect(throws: ConversionError.invalidResponse) {
            try await makeClient().complete(system: "sys", user: "きょう")
        }
    }

    @Test func rejectsNullContent() async {
        replyJSON(#"{"choices":[{"message":{"content":null}}]}"#)
        await #expect(throws: ConversionError.emptyResult) {
            try await makeClient().complete(system: "sys", user: "きょう")
        }
    }

    @Test func requiresModel() async {
        await #expect(throws: ConversionError.modelNotConfigured) {
            try await makeClient(model: " ").complete(system: "sys", user: "きょう")
        }
    }

    // MARK: - Endpoint URL

    @Test(arguments: [
        "http://localhost:1234/v1",
        "http://localhost:1234/v1/",
        "http://localhost:1234/v1//",
        " http://localhost:1234/v1 ",
        "http://localhost:1234/v1/chat/completions",
    ])
    func normalizesBaseURL(baseURL: String) throws {
        let url = try OpenAICompatibleClient.endpointURL(baseURL: baseURL, allowLocalNetworkHTTP: false)
        #expect(url.absoluteString == "http://localhost:1234/v1/chat/completions")
    }

    @Test func allowsHTTPS() throws {
        let url = try OpenAICompatibleClient.endpointURL(baseURL: "https://api.example.com/v1", allowLocalNetworkHTTP: false)
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func rejectsRemoteHTTP() {
        #expect(throws: ConversionError.insecureHTTP) {
            try OpenAICompatibleClient.endpointURL(baseURL: "http://api.example.com/v1", allowLocalNetworkHTTP: true)
        }
    }

    @Test func localNetworkHTTPRequiresOptIn() throws {
        #expect(throws: ConversionError.insecureHTTP) {
            try OpenAICompatibleClient.endpointURL(baseURL: "http://192.168.1.10:1234/v1", allowLocalNetworkHTTP: false)
        }
        let url = try OpenAICompatibleClient.endpointURL(baseURL: "http://192.168.1.10:1234/v1", allowLocalNetworkHTTP: true)
        #expect(url.host == "192.168.1.10")
    }

    @Test(arguments: ["", "localhost:1234", "ftp://localhost/v1"])
    func rejectsInvalidBaseURL(baseURL: String) {
        #expect(throws: ConversionError.invalidBaseURL) {
            try OpenAICompatibleClient.endpointURL(baseURL: baseURL, allowLocalNetworkHTTP: false)
        }
    }
}
