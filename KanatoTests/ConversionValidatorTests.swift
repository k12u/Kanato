//
//  ConversionValidatorTests.swift
//  KanatoTests
//

import Testing
@testable import Kanato

struct ConversionValidatorTests {
    let validator = ConversionValidator()

    @Test func acceptsPlainConversion() throws {
        let result = try validator.validate(output: "今日はいい天気です", input: "きょうはいいてんきです")
        #expect(result == "今日はいい天気です")
    }

    @Test func trimsWhitespaceAddedByModel() throws {
        let result = try validator.validate(output: "\n  今日はいい天気です \n", input: "きょうはいいてんきです")
        #expect(result == "今日はいい天気です")
    }

    @Test func restoresInputLeadingAndTrailingWhitespace() throws {
        let result = try validator.validate(output: "今日は晴れ", input: "  きょうははれ\n")
        #expect(result == "  今日は晴れ\n")
    }

    @Test func keepsInternalNewlines() throws {
        let result = try validator.validate(output: "一行目\n二行目", input: "いちぎょうめ\nにぎょうめ")
        #expect(result == "一行目\n二行目")
    }

    @Test(arguments: ["", "   ", "\n\n"])
    func rejectsEmptyOutput(output: String) {
        #expect(throws: ConversionError.emptyResult) {
            try validator.validate(output: output, input: "きょう")
        }
    }

    @Test func rejectsCodeFence() {
        #expect(throws: ConversionError.unexpectedFormat("コードフェンス")) {
            try validator.validate(output: "```\n今日\n```", input: "きょう")
        }
    }

    @Test func allowsCodeFenceWhenInputHasOne() throws {
        let input = "つぎのこーど\n```\nprint(1)\n```"
        let output = "次のコード\n```\nprint(1)\n```"
        #expect(try validator.validate(output: output, input: input) == output)
    }

    @Test func rejectsJSONOutput() {
        #expect(throws: ConversionError.unexpectedFormat("JSON")) {
            try validator.validate(output: #"{"result": "今日"}"#, input: "きょう")
        }
    }

    @Test(arguments: ["変換結果：今日", "Here is the result: 今日", "以下が変換後の文章です。\n今日"])
    func rejectsExplanation(output: String) {
        #expect(throws: (any Error).self) {
            try validator.validate(output: output, input: "きょう")
        }
    }

    @Test(arguments: ["「今日」", "\"今日\"", "“今日”"])
    func rejectsAddedQuotes(output: String) {
        #expect(throws: ConversionError.unexpectedFormat("引用符")) {
            try validator.validate(output: output, input: "きょう")
        }
    }

    @Test func allowsQuotesPresentInInput() throws {
        #expect(try validator.validate(output: "「今日」", input: "「きょう」") == "「今日」")
    }

    @Test func rejectsTooLongOutput() {
        let input = "きょう"
        let output = String(repeating: "あ", count: validator.maxOutputLength(forInputLength: input.count) + 1)
        #expect(throws: ConversionError.outputTooLong) {
            try validator.validate(output: output, input: input)
        }
    }

    @Test func removesThinkBlock() throws {
        let result = try validator.validate(output: "<think>考え中</think>\n今日", input: "きょう")
        #expect(result == "今日")
    }
}
