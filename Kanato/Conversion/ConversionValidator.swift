//
//  ConversionValidator.swift
//  Kanato
//

import Foundation

/// LLM の出力を検証する。不自然な出力はエラーにし、元の文章を維持させる。
nonisolated struct ConversionValidator: Sendable {
    /// 出力の最大文字数 = 入力文字数 × outputLengthRatio + outputLengthSlack
    var outputLengthRatio = 2
    var outputLengthSlack = 32

    func maxOutputLength(forInputLength length: Int) -> Int {
        length * outputLengthRatio + outputLengthSlack
    }

    /// 検証済みの変換結果を返す。
    /// 前後の空白は LLM 出力から除去し、原文が持っていた前後空白（末尾改行など）だけを復元する。
    func validate(output rawOutput: String, input: String) throws -> String {
        var body = Self.removingThinkBlock(rawOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { throw ConversionError.emptyResult }

        let inputBody = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if body.contains("```") && !inputBody.contains("```") {
            throw ConversionError.unexpectedFormat("コードフェンス")
        }
        if Self.looksLikeJSON(body) && !Self.looksLikeJSON(inputBody) {
            throw ConversionError.unexpectedFormat("JSON")
        }
        if let prefix = Self.explanationPrefixes.first(where: { body.hasPrefix($0) && !inputBody.hasPrefix($0) }) {
            throw ConversionError.unexpectedFormat("説明文: \(prefix)")
        }
        if Self.isWrappedInQuotes(body) && !Self.isWrappedInQuotes(inputBody) {
            throw ConversionError.unexpectedFormat("引用符")
        }
        if body.count > maxOutputLength(forInputLength: inputBody.count) {
            throw ConversionError.outputTooLong
        }

        body = Self.leadingWhitespace(of: input) + body + Self.trailingWhitespace(of: input)
        return body
    }

    // MARK: - Helpers

    /// 説明文の書き出しとしてよく見られるもの
    static let explanationPrefixes = [
        "変換結果", "変換後", "以下", "出力:", "出力：", "結果:", "結果：",
        "Here is", "Here's", "Output:", "Result:", "Converted",
    ]

    private static let quotePairs: [(Character, Character)] = [
        ("「", "」"), ("『", "』"), ("\"", "\""), ("“", "”"), ("'", "'"),
    ]

    static func isWrappedInQuotes(_ text: String) -> Bool {
        guard text.count >= 2, let first = text.first, let last = text.last else { return false }
        return quotePairs.contains { $0.0 == first && $0.1 == last }
    }

    static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        guard (first == "{" && last == "}") || (first == "[" && last == "]") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    /// 推論モデルが出力する先頭の <think>...</think> を取り除く
    static func removingThinkBlock(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<think>"), let end = trimmed.range(of: "</think>") else { return text }
        return String(trimmed[end.upperBound...])
    }

    static func leadingWhitespace(of text: String) -> String {
        String(text.prefix { $0.isWhitespace })
    }

    static func trailingWhitespace(of text: String) -> String {
        guard text.contains(where: { !$0.isWhitespace }) else { return "" }
        return String(text.reversed().prefix { $0.isWhitespace }.reversed())
    }
}
