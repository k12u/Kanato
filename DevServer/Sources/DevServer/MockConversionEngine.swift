//
//  MockConversionEngine.swift
//  DevServer
//
//  固定マッピングによる疑似変換。形態素解析や推論は行わない。
//

import Foundation

struct MockConversionEngine: Sendable {
    static let defaultMappings: [String: String] = [
        "きょうはいいてんきです": "今日はいい天気です",
        "このしようはまだかくていしていない": "この仕様はまだ確定していない",
        "らいしゅうのかいぎでかくにんする": "来週の会議で確認する",
        "ぱいそんでじっそうする": "Pythonで実装する",
        "てすと": "テスト",
    ]

    var mappings: [String: String] = Self.defaultMappings

    /// 前後の空白を除いて固定マッピングを引く。未登録の場合は入力をそのまま返す。
    func convert(_ input: String) -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return mappings[key] ?? input
    }

    /// Chat Completions の messages から、最後の `role: user` の content を取り出す
    static func extractInput(from messages: [ChatCompletionRequest.Message]) -> String? {
        messages.last { $0.role == "user" }?.content
    }
}
