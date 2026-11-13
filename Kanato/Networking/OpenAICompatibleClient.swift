//
//  OpenAICompatibleClient.swift
//  Kanato
//

import Foundation
import os

/// LLM 呼び出しの抽象。テストではモックを注入する。
nonisolated protocol ChatCompletionClient: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// OpenAI 互換 API の接続設定
nonisolated struct LLMConfiguration: Sendable, Equatable {
    var baseURL: String
    var model: String
    var apiKey: String?
    var timeout: TimeInterval
    /// nil の場合はリクエストに含めない（temperature 非対応モデル向け）
    var temperature: Double?
    /// localhost 以外のローカルネットワーク (.local / プライベートIP) への HTTP を許可するか
    var allowLocalNetworkHTTP: Bool
}

/// `POST {baseURL}/chat/completions` を呼び出すクライアント
nonisolated struct OpenAICompatibleClient: ChatCompletionClient {
    let configuration: LLMConfiguration
    let session: URLSession

    private static let logger = Logger(subsystem: "org.k12u.Kanato", category: "Networking")

    init(configuration: LLMConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = configuration.timeout
            config.waitsForConnectivity = false
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    func complete(system: String, user: String) async throws -> String {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ConversionError.modelNotConfigured }

        let url = try Self.endpointURL(
            baseURL: configuration.baseURL,
            allowLocalNetworkHTTP: configuration.allowLocalNetworkHTTP
        )

        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
                temperature: configuration.temperature,
                stream: false
            )
        )

        let start = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        Self.logger.info("HTTP request finished in \(ContinuousClock.now - start, privacy: .public)")

        guard let http = response as? HTTPURLResponse else { throw ConversionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            Self.logger.error("HTTP status \(http.statusCode, privacy: .public)")
            throw ConversionError.httpStatus(http.statusCode)
        }

        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ConversionError.invalidResponse
        }
        guard let first = decoded.choices.first else { throw ConversionError.invalidResponse }
        guard let content = first.message.content else { throw ConversionError.emptyResult }
        return content
    }

    // MARK: - URL

    /// baseURL の末尾スラッシュを正規化し、`/chat/completions` を一度だけ付加する
    static func endpointURL(baseURL: String, allowLocalNetworkHTTP: Bool) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            base.removeLast("/chat/completions".count)
        }

        guard let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let url = URL(string: base + "/chat/completions")
        else { throw ConversionError.invalidBaseURL }

        switch scheme {
        case "https":
            return url
        case "http":
            if isLoopback(host) || (allowLocalNetworkHTTP && isLocalNetwork(host)) {
                return url
            }
            throw ConversionError.insecureHTTP
        default:
            throw ConversionError.invalidBaseURL
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
    }

    /// .local ドメインとプライベート IPv4 アドレス
    static func isLocalNetwork(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") { return true }
        let octets = h.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, h.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    // MARK: - Errors

    static func mapTransportError(_ error: any Error) -> ConversionError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .cannotConnect }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        case .appTransportSecurityRequiresSecureConnection: return .insecureHTTP
        case .badURL, .unsupportedURL: return .invalidBaseURL
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
            return .invalidResponse
        default: return .cannotConnect
        }
    }
}

// MARK: - Wire format

nonisolated struct ChatRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    /// nil の場合はキー自体を出力しない
    let temperature: Double?
    let stream: Bool
}

nonisolated struct ChatResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}
