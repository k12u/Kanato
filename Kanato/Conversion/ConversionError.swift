//
//  ConversionError.swift
//  Kanato
//

import Foundation

/// 変換処理で発生するエラー。いずれの場合も元のテキストは変更しない。
/// メッセージには入力本文・変換本文・APIキーを含めない。
nonisolated enum ConversionError: LocalizedError, Equatable, Sendable {
    case emptyInput
    case inputTooLong(limit: Int)
    case modelNotConfigured
    case invalidBaseURL
    case insecureHTTP
    case cannotConnect
    case timeout
    case httpStatus(Int)
    case invalidResponse
    case emptyResult
    case outputTooLong
    case unexpectedFormat(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyInput: "変換するテキストが空です"
        case .inputTooLong(let limit): "選択テキストが長すぎます（最大\(limit)文字）"
        case .modelNotConfigured: "Model IDが設定されていません"
        case .invalidBaseURL: "API Base URLが不正です"
        case .insecureHTTP: "HTTPはlocalhost（または許可したローカルネットワーク）でのみ利用できます"
        case .cannotConnect: "LLMサーバーに接続できません"
        case .timeout: "LLMサーバーの応答がタイムアウトしました"
        case .httpStatus(let code): "LLMサーバーがエラーを返しました（HTTP \(code)）"
        case .invalidResponse: "LLMサーバーのレスポンスが不正です"
        case .emptyResult: "変換結果が空です"
        case .outputTooLong: "変換結果が長すぎます"
        case .unexpectedFormat(let reason): "変換結果の形式が不正です（\(reason)）"
        case .cancelled: "変換がキャンセルされました"
        }
    }
}
