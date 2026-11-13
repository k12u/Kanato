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

/// プロンプトをそのまま補完させる呼び出しの抽象（zenz などチャット形式でないモデル向け）
nonisolated protocol TextCompletionClient: Sendable {
    func completeText(prompt: String, maxTokens: Int) async throws -> String
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

/// `POST {baseURL}/chat/completions`（チャット）と `POST {baseURL}/completions`（テキスト補完）を呼び出すクライアント
nonisolated struct OpenAICompatibleClient: ChatCompletionClient, TextCompletionClient {
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

        let data = try await post(
            ChatRequest(
                model: model,
                messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
                temperature: configuration.temperature,
                stream: false
            ),
            path: Self.chatCompletionsPath
        )
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ConversionError.invalidResponse
        }
        guard let first = decoded.choices.first else { throw ConversionError.invalidResponse }
        guard let content = first.message.content else { throw ConversionError.emptyResult }
        return content
    }

    /// Model ID は任意（llama-server のように 1 モデルだけを提供するサーバーでは不要）
    func completeText(prompt: String, maxTokens: Int) async throws -> String {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try await post(
            CompletionRequest(
                model: model.isEmpty ? nil : model,
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: configuration.temperature,
                stream: false
            ),
            path: Self.completionsPath
        )
        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data) else {
            throw ConversionError.invalidResponse
        }
        guard let first = decoded.choices.first else { throw ConversionError.invalidResponse }
        guard let text = first.text else { throw ConversionError.emptyResult }
        return text
    }

    /// JSON を POST し、2xx のレスポンス本文を返す
    private func post(_ body: some Encodable, path: String) async throws -> Data {
        let url = try Self.endpointURL(
            baseURL: configuration.baseURL,
            path: path,
            allowLocalNetworkHTTP: configuration.allowLocalNetworkHTTP
        )

        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

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
        return data
    }

    // MARK: - URL

    static let chatCompletionsPath = "/chat/completions"
    static let completionsPath = "/completions"

    /// baseURL の末尾スラッシュを正規化し、エンドポイントのパスを一度だけ付加する
    static func endpointURL(
        baseURL: String,
        path: String = chatCompletionsPath,
        allowLocalNetworkHTTP: Bool
    ) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        // エンドポイントまで入力された場合も受け付ける（/chat/completions を先に判定する）
        for suffix in [chatCompletionsPath, completionsPath] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }

        guard let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let url = URL(string: base + path)
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

/// OpenAI 互換の Completions（`/completions`）リクエスト
nonisolated struct CompletionRequest: Encodable, Sendable {
    /// nil の場合はキー自体を出力しない
    let model: String?
    let prompt: String
    let maxTokens: Int
    /// nil の場合はキー自体を出力しない
    let temperature: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, prompt, temperature, stream
        case maxTokens = "max_tokens"
    }
}

nonisolated struct CompletionResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        let text: String?
    }
    let choices: [Choice]
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
