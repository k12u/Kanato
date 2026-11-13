//
//  ConversionPrompt.swift
//  Kanato
//

import Foundation

/// 変換モードごとのシステムプロンプト。MVP では Literal のみ。
nonisolated enum ConversionPrompt: Sendable {
    case literal

    var systemPrompt: String {
        switch self {
        case .literal:
            return """
            あなたは日本語のかな漢字変換エンジンです。

            入力された日本語文章を、自然な漢字交じり文に変換してください。

            ルール：
            - 原文の意味、語順、文体を変更しない
            - 言い換えや要約をしない
            - 漢字とカタカナへの変換のみを基本とする
            - 固有名詞や専門用語は文脈に応じて変換する
            - 元の改行を維持する
            - 句読点は原則として元のまま維持する
            - 不明な箇所は無理に漢字へ変換しない
            - 説明文、引用符、Markdownを出力しない
            - 変換後の文字列のみを出力する
            """
        }
    }
}
