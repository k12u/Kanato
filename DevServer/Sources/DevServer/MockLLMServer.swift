//
//  MockLLMServer.swift
//  DevServer
//

import Foundation
import Hummingbird

/// 障害シミュレーションのモード（KANAFILTER_MOCK_MODE）
enum MockMode: String, CaseIterable, Sendable {
    case normal
    case http500
    case emptyChoices = "empty_choices"
    case emptyContent = "empty_content"
    case invalidJSON = "invalid_json"
}

struct ServerConfiguration: Sendable, Equatable {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8765
    static let modelID = "kanafilter-mock"

    var host = Self.defaultHost
    var port = Self.defaultPort
    var mode = MockMode.normal
    var delayMilliseconds = 0

    var delay: Duration { .milliseconds(delayMilliseconds) }

    struct InvalidValue: Error, CustomStringConvertible {
        let description: String
    }

    /// 環境変数から設定を読む。未設定の項目は既定値、不正な値はエラー。
    static func fromEnvironment(_ environment: [String: String]) throws -> ServerConfiguration {
        var configuration = ServerConfiguration()
        if let host = environment["KANAFILTER_MOCK_HOST"], !host.isEmpty {
            configuration.host = host
        }
        if let value = environment["KANAFILTER_MOCK_PORT"], !value.isEmpty {
            guard let port = Int(value), (1...65535).contains(port) else {
                throw InvalidValue(description: "KANAFILTER_MOCK_PORT must be 1-65535: \(value)")
            }
            configuration.port = port
        }
        if let value = environment["KANAFILTER_MOCK_MODE"], !value.isEmpty {
            guard let mode = MockMode(rawValue: value) else {
                let names = MockMode.allCases.map(\.rawValue).joined(separator: ", ")
                throw InvalidValue(description: "KANAFILTER_MOCK_MODE must be one of [\(names)]: \(value)")
            }
            configuration.mode = mode
        }
        if let value = environment["KANAFILTER_MOCK_DELAY_MS"], !value.isEmpty {
            guard let milliseconds = Int(value), milliseconds >= 0 else {
                throw InvalidValue(description: "KANAFILTER_MOCK_DELAY_MS must be a non-negative integer: \(value)")
            }
            configuration.delayMilliseconds = milliseconds
        }
        return configuration
    }

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }
}

/// OpenAI 互換 Mock LLM Server
struct MockLLMServer: Sendable {
    /// リクエストボディの上限
    static let maxBodySize = 1 << 20

    let configuration: ServerConfiguration
    var engine = MockConversionEngine()

    func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()

        router.get("health") { _, _ in
            try Self.json(HealthResponse(status: "ok", service: "KanaFilter DevServer"))
        }

        router.get("v1/models") { _, _ in
            try Self.json(ModelList(object: "list", data: [
                .init(id: ServerConfiguration.modelID, object: "model", created: 0, ownedBy: "kanafilter"),
            ]))
        }

        router.post("v1/chat/completions") { request, _ in
            try await chatCompletions(request)
        }

        return router
    }

    func buildApplication(
        onServerRunning: @escaping @Sendable () async -> Void = {}
    ) -> some ApplicationProtocol {
        Application(
            router: buildRouter(),
            configuration: .init(
                address: .hostname(configuration.host, port: configuration.port),
                serverName: "KanaFilter DevServer"
            ),
            onServerRunning: { _ in await onServerRunning() }
        )
    }

    // MARK: - Chat Completions

    func chatCompletions(_ request: Request) async throws -> Response {
        var request = request
        let body = try await request.collectBody(upTo: Self.maxBodySize)

        let chatRequest: ChatCompletionRequest
        do {
            chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(buffer: body))
        } catch {
            return try Self.error(.badRequest, "Request body is not a valid chat completion request")
        }

        if chatRequest.stream == true {
            return try Self.error(.badRequest, "stream=true is not supported by KanaFilter DevServer", param: "stream")
        }
        guard chatRequest.model == ServerConfiguration.modelID else {
            return try Self.error(
                .badRequest,
                "The model '\(chatRequest.model)' does not exist. Use '\(ServerConfiguration.modelID)'.",
                code: "model_not_found"
            )
        }
        guard !chatRequest.messages.isEmpty else {
            return try Self.error(.badRequest, "messages must not be empty", param: "messages")
        }
        guard let input = MockConversionEngine.extractInput(from: chatRequest.messages) else {
            return try Self.error(.badRequest, "messages must contain a user message", param: "messages")
        }

        if configuration.delay > .zero {
            try await Task.sleep(for: configuration.delay)
        }

        switch configuration.mode {
        case .normal:
            return try Self.json(ChatCompletionResponse.make(model: chatRequest.model, content: engine.convert(input)))
        case .http500:
            return try Self.error(.internalServerError, "Simulated server error", type: "server_error")
        case .emptyChoices:
            return try Self.json(ChatCompletionResponse.make(model: chatRequest.model, content: nil))
        case .emptyContent:
            return try Self.json(ChatCompletionResponse.make(model: chatRequest.model, content: ""))
        case .invalidJSON:
            // Content-Type は JSON のまま、壊れた本文を返す
            return Self.raw(#"{"id":"chatcmpl-mock-001","choices":[{"message":{"content":"#)
        }
    }

    // MARK: - Response helpers

    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: try encoder.encode(value)))
        )
    }

    static func raw(_ text: String, status: HTTPResponse.Status = .ok) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: text))
        )
    }

    static func error(
        _ status: HTTPResponse.Status,
        _ message: String,
        type: String = "invalid_request_error",
        param: String? = nil,
        code: String? = nil
    ) throws -> Response {
        try json(ErrorResponse(message: message, type: type, param: param, code: code), status: status)
    }
}
