//
//  ConversionService.swift
//  Kanato
//

import Foundation

/// かな漢字変換のユースケース。UI や AppKit には依存しない。
nonisolated struct ConversionService: Sendable {
    static let maxInputLength = 4000

    let client: any ChatCompletionClient
    var prompt: ConversionPrompt = .literal
    var validator = ConversionValidator()

    func convert(text: String) async throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ConversionError.emptyInput }
        guard body.count <= Self.maxInputLength else {
            throw ConversionError.inputTooLong(limit: Self.maxInputLength)
        }

        let output = try await client.complete(system: prompt.systemPrompt, user: body)
        try Task.checkCancellation()
        return try validator.validate(output: output, input: text)
    }
}
