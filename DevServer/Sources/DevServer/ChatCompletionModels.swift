//
//  ChatCompletionModels.swift
//  DevServer
//
//  OpenAI Chat Completions API のうち、Kanato の MVP に必要な部分集合だけを定義する。
//

import Foundation

struct ChatCompletionRequest: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let content: String?

        private enum CodingKeys: String, CodingKey {
            case role, content
        }

        private struct ContentPart: Decodable {
            let type: String
            let text: String?
        }

        init(role: String, content: String?) {
            self.role = role
            self.content = content
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
            // content は文字列のほか、テキストパートの配列も受け付ける
            if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
                content = text
            } else if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
                content = parts.filter { $0.type == "text" }.compactMap(\.text).joined()
            } else {
                content = nil
            }
        }
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let stream: Bool?
}

struct ChatCompletionResponse: Encodable, Sendable {
    struct Choice: Encodable, Sendable {
        let index: Int
        let message: Message
        let finishReason: String

        private enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]

    static func make(model: String, content: String?) -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "chatcmpl-mock-001",
            object: "chat.completion",
            created: 0,
            model: model,
            choices: content.map {
                [Choice(index: 0, message: Message(role: "assistant", content: $0), finishReason: "stop")]
            } ?? []
        )
    }
}

struct ModelList: Encodable, Sendable {
    struct Model: Encodable, Sendable {
        let id: String
        let object: String
        let created: Int
        let ownedBy: String

        private enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }

    let object: String
    let data: [Model]
}

struct HealthResponse: Encodable, Sendable {
    let status: String
    let service: String
}

/// OpenAI 形式のエラーレスポンス
struct ErrorResponse: Encodable, Sendable {
    struct Body: Encodable, Sendable {
        let message: String
        let type: String
        let param: String?
        let code: String?

        // OpenAI と同様に、値がなくても param / code は null として出力する
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encode(type, forKey: .type)
            try container.encode(param, forKey: .param)
            try container.encode(code, forKey: .code)
        }

        private enum CodingKeys: String, CodingKey {
            case message, type, param, code
        }
    }

    let error: Body

    init(message: String, type: String = "invalid_request_error", param: String? = nil, code: String? = nil) {
        error = Body(message: message, type: type, param: param, code: code)
    }
}
