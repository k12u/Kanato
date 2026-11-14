//
//  ZenzBackend.swift
//  Kanato
//

import Foundation

/// かな漢字変換専用モデル zenz（v2.5）で変換するバックエンド。
///
/// zenz はチャットモデルではなく、`U+EE00 + カタカナ入力 + U+EE01` に続けて変換結果を生成する。
/// OpenAI 互換の Completions（llama-server の `/v1/completions` など）で呼び出す。
/// - 入力のひらがなはカタカナに変換して渡す
/// - 改行ごとに変換し、各行の前後空白・空行は原文のまま残す
/// - 英字を含む ASCII の並び（"Apple Developer" など）はモデルに渡さずそのまま残す。
///   zenz はかなの読みを前提としており、ASCII を含めると出力が崩れるため
/// - 分割したかなの部分には、同じ行でそれまでに変換した結果を左文脈として渡す
///   （v2 系: `U+EE00 入力 U+EE02 文脈 U+EE01`、v3 系: `U+EE02 文脈 U+EE00 入力 U+EE01`。
///   AzooKeyKanaKanjiConverter の ZenzPromptBuilder と同じ）
/// - コンテキスト長（1024 トークン、文字単位）を超えないよう、長い行は文末・読点で分割する
nonisolated struct ZenzBackend: InferenceBackend {
    static let inputTag = "\u{EE00}"
    static let outputTag = "\u{EE01}"
    static let contextTag = "\u{EE02}"
    /// 1 回の生成で扱う最大文字数（プロンプト + 出力がコンテキスト長に収まるように）
    static let maxChunkLength = 200
    /// 左文脈として渡す最大文字数（AzooKeyKanaKanjiConverter の既定値と同じ）
    static let maxContextLength = 40
    /// 制御タグ（私用領域）。出力に含まれていたら不正とみなす
    private static let reservedScalars: ClosedRange<Unicode.Scalar> = "\u{EE00}"..."\u{EEFF}"

    /// zenz のバージョンごとのプロンプト形式
    enum PromptVersion: Sendable {
        case v2
        case v3
    }

    let client: any TextCompletionClient
    var promptVersion: PromptVersion = .v2
    var validator = ConversionValidator(rejectsExplanationPrefixes: false)

    func convert(_ text: String) async throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ConversionError.emptyInput }
        guard body.count <= ConversionService.maxInputLength else {
            throw ConversionError.inputTooLong(limit: ConversionService.maxInputLength)
        }
        guard !text.unicodeScalars.contains(where: Self.reservedScalars.contains) else {
            throw ConversionError.unexpectedFormat("入力に制御文字")
        }

        // "\r\n" も "\n" で分割され、"\r" は行末の空白として保持される
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            try Task.checkCancellation()
            lines.append(try await convertLine(line))
        }
        return lines.joined(separator: "\n")
    }

    private func convertLine(_ line: String) async throws -> String {
        let core = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return line }

        var converted = ""
        for segment in Self.segments(of: core) {
            guard case .convert(let text) = segment else {
                if case .passthrough(let text) = segment { converted += text }
                continue
            }
            for chunk in Self.chunks(of: text, limit: Self.maxChunkLength) {
                try Task.checkCancellation()
                let output = try await client.completeText(
                    prompt: Self.prompt(for: chunk, leftContext: String(converted.suffix(Self.maxContextLength)), version: promptVersion),
                    maxTokens: chunk.count * 2 + 16
                )
                guard !output.unicodeScalars.contains(where: Self.reservedScalars.contains) else {
                    throw ConversionError.unexpectedFormat("制御タグ")
                }
                // チャンク内部の前後空白は validator が原文どおりに復元する
                converted += try validator.validate(output: output, input: chunk)
            }
        }
        return ConversionValidator.leadingWhitespace(of: line) + converted + ConversionValidator.trailingWhitespace(of: line)
    }

    static func prompt(for text: String, leftContext: String = "", version: PromptVersion = .v2) -> String {
        let input = inputTag + katakana(from: text)
        let context = leftContext.isEmpty ? "" : contextTag + leftContext
        switch version {
        case .v2: return input + context + outputTag
        case .v3: return context + input + outputTag
        }
    }

    enum Segment: Equatable {
        /// モデルに渡さずそのまま出力する
        case passthrough(String)
        /// zenz で変換する
        case convert(String)
    }

    /// 行を「そのまま残す部分」と「変換する部分」に分ける。
    /// - 英字を含む ASCII の並び（空白・数字・記号を含む）はそのまま残す
    /// - 英字を含まない ASCII（"3" や "-" など）は前後のかなと一緒に変換する（"ごご3じ" → "午後3時"）
    /// - ひらがなを含まない部分は変換する必要がないためそのまま残す
    static func segments(of text: String) -> [Segment] {
        // 1. ASCII の並びとそれ以外に分ける
        var runs: [(text: String, isASCII: Bool)] = []
        for character in text {
            let isASCII = character.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
            if let last = runs.last, last.isASCII == isASCII {
                runs[runs.count - 1].text.append(character)
            } else {
                runs.append((String(character), isASCII))
            }
        }

        // 2. 英字を含む ASCII の並びを区切りに、残りをまとめる
        var segments: [Segment] = []
        var pending = ""
        func flushPending() {
            guard !pending.isEmpty else { return }
            let hasHiragana = pending.unicodeScalars.contains { (0x3041...0x309F).contains($0.value) }
            segments.append(hasHiragana ? .convert(pending) : .passthrough(pending))
            pending = ""
        }
        for run in runs {
            if run.isASCII && run.text.contains(where: { $0.isASCII && $0.isLetter }) {
                flushPending()
                segments.append(.passthrough(run.text))
            } else {
                pending += run.text
            }
        }
        flushPending()

        // 3. 隣り合うそのまま残す部分を結合する
        return segments.reduce(into: []) { result, segment in
            if case .passthrough(let text) = segment, case .passthrough(let previous)? = result.last {
                result[result.count - 1] = .passthrough(previous + text)
            } else {
                result.append(segment)
            }
        }
    }

    /// ひらがな（ぁ〜ゖ・ゝゞ）をカタカナに変換する。それ以外の文字はそのまま
    static func katakana(from text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3041...0x3096, 0x309D...0x309E:
                scalars.append(Unicode.Scalar(scalar.value + 0x60) ?? scalar)
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", "．"]
    private static let clauseEnds: Set<Character> = ["、", "，", ",", " ", "　"]

    /// limit 文字以下に分割する。文末 → 読点・空白の順に区切りを探し、見つからなければ limit で切る
    static func chunks(of text: String, limit: Int) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: sentenceEnds.contains)
                ?? window.lastIndex(where: clauseEnds.contains)
            let end = cut.map { rest.index(after: $0) } ?? window.endIndex
            result.append(String(rest[..<end]))
            rest = rest[end...]
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }
}
