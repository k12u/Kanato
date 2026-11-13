//
//  KanaServiceProviderTests.swift
//  KanatoTests
//

import AppKit
import Foundation
import Testing
@testable import Kanato

/// DevServer (Mock LLM Server) の各 Mock Mode が返すレスポンスを再生する URLProtocol スタブ。
/// 他のスイートの `StubURLProtocol` と状態を共有しないよう独立させている。
nonisolated final class DevServerReplayURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(status: Int, body: String)
        case failure(URLError.Code)
    }

    nonisolated(unsafe) static var reply: Reply = .failure(.cannotConnectToHost)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.reply {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

/// Mock Server が異常レスポンスを返しても、サービスの選択文字列 (pasteboard) が失われないことを確認する
@MainActor
@Suite(.serialized)
struct KanaServiceProviderTests {

    /// DevServer の実レスポンス (curl で採取) と、サーバー停止・タイムアウト
    enum DevServerMode: String, CaseIterable {
        case http500, emptyChoices, emptyContent, invalidJSON, serverStopped, timeout

        var reply: DevServerReplayURLProtocol.Reply {
            switch self {
            case .http500:
                .response(status: 500, body: #"{"error":{"code":null,"message":"Simulated server error","param":null,"type":"server_error"}}"#)
            case .emptyChoices:
                .response(status: 200, body: #"{"choices":[],"created":0,"id":"chatcmpl-mock-001","model":"kanafilter-mock","object":"chat.completion"}"#)
            case .emptyContent:
                .response(status: 200, body: #"{"choices":[{"finish_reason":"stop","index":0,"message":{"content":"","role":"assistant"}}],"created":0,"id":"chatcmpl-mock-001","model":"kanafilter-mock","object":"chat.completion"}"#)
            case .invalidJSON:
                .response(status: 200, body: #"{"id":"chatcmpl-mock-001","choices":[{"message":{"content":"#)
            case .serverStopped:
                .failure(.cannotConnectToHost)
            case .timeout:
                .failure(.timedOut)
            }
        }
    }

    private static let configuration = LLMConfiguration(
        baseURL: "http://127.0.0.1:8765/v1", model: "kanafilter-mock", apiKey: nil,
        timeout: 2, temperature: 0, allowLocalNetworkHTTP: false
    )

    private func makeProvider() -> KanaServiceProvider {
        KanaServiceProvider(
            loadConfiguration: { Self.configuration },
            makeClient: { configuration in
                let sessionConfiguration = URLSessionConfiguration.ephemeral
                sessionConfiguration.protocolClasses = [DevServerReplayURLProtocol.self]
                return OpenAICompatibleClient(
                    configuration: configuration,
                    session: URLSession(configuration: sessionConfiguration)
                )
            }
        )
    }

    /// サービス呼び出しを行い、呼び出し後の pasteboard の文字列とエラーメッセージを返す
    private func performService(input: String) -> (pasteboard: String?, error: String?) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.k12u.Kanato.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(input, forType: .string)

        var message: NSString?
        makeProvider().convertKana(pasteboard, userData: nil, error: &message)
        return (pasteboard.string(forType: .string), message as String?)
    }

    @Test func replacesSelectionOnNormalResponse() {
        DevServerReplayURLProtocol.reply = .response(
            status: 200,
            body: #"{"choices":[{"finish_reason":"stop","index":0,"message":{"content":"今日はいい天気です","role":"assistant"}}],"created":0,"id":"chatcmpl-mock-001","model":"kanafilter-mock","object":"chat.completion"}"#
        )
        let result = performService(input: "きょうはいいてんきです")
        #expect(result.pasteboard == "今日はいい天気です")
        #expect(result.error == nil)
    }

    @Test(arguments: DevServerMode.allCases)
    func keepsOriginalSelectionOnFailure(mode: DevServerMode) {
        DevServerReplayURLProtocol.reply = mode.reply
        let original = "きょうはいいてんきです\n"
        let result = performService(input: original)
        #expect(result.pasteboard == original)
        #expect(result.error?.hasPrefix("Kanato: ") == true)
    }
}
