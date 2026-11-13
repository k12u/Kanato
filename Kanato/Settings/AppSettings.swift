//
//  AppSettings.swift
//  Kanato
//

import Foundation
import Observation

/// 接続設定。API キー以外は UserDefaults に保存する。
@Observable
final class AppSettings {
    nonisolated static let defaultBaseURL = "http://localhost:1234/v1"
    nonisolated static let defaultTimeout: TimeInterval = 8
    /// サービスの NSTimeout (15 秒) より必ず短くする
    nonisolated static let timeoutRange: ClosedRange<TimeInterval> = 1...12

    private nonisolated enum Keys {
        static let baseURL = "baseURL"
        static let model = "model"
        static let timeout = "timeout"
        static let sendTemperature = "sendTemperature"
        static let allowLocalNetworkHTTP = "allowLocalNetworkHTTP"
    }

    var baseURL: String
    var model: String
    var apiKey: String
    var timeout: TimeInterval
    var sendTemperature: Bool
    var allowLocalNetworkHTTP: Bool

    init(defaults: UserDefaults = .standard) {
        let stored = Self.loadConfiguration(defaults: defaults, includeAPIKey: true)
        baseURL = stored.baseURL
        model = stored.model
        apiKey = stored.apiKey ?? ""
        timeout = stored.timeout
        sendTemperature = stored.temperature != nil
        allowLocalNetworkHTTP = stored.allowLocalNetworkHTTP
    }

    /// 画面上の (未保存を含む) 値から接続設定を作る
    var configuration: LLMConfiguration {
        LLMConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            timeout: timeout.clamped(to: Self.timeoutRange),
            temperature: sendTemperature ? 0 : nil,
            allowLocalNetworkHTTP: allowLocalNetworkHTTP
        )
    }

    /// API キーの保存に失敗した場合は false
    @discardableResult
    func save(defaults: UserDefaults = .standard) -> Bool {
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model)
        defaults.set(timeout.clamped(to: Self.timeoutRange), forKey: Keys.timeout)
        defaults.set(sendTemperature, forKey: Keys.sendTemperature)
        defaults.set(allowLocalNetworkHTTP, forKey: Keys.allowLocalNetworkHTTP)
        return APIKeyStore.save(apiKey)
    }

    /// 保存済みの接続設定を読み出す（サービス実行時に毎回呼ぶ）
    nonisolated static func loadConfiguration(
        defaults: UserDefaults = .standard,
        includeAPIKey: Bool = true
    ) -> LLMConfiguration {
        let timeout = defaults.object(forKey: Keys.timeout) as? Double ?? defaultTimeout
        let sendTemperature = defaults.object(forKey: Keys.sendTemperature) as? Bool ?? true
        return LLMConfiguration(
            baseURL: defaults.string(forKey: Keys.baseURL) ?? defaultBaseURL,
            model: defaults.string(forKey: Keys.model) ?? "",
            apiKey: includeAPIKey ? APIKeyStore.load() : nil,
            timeout: timeout.clamped(to: timeoutRange),
            temperature: sendTemperature ? 0 : nil,
            allowLocalNetworkHTTP: defaults.bool(forKey: Keys.allowLocalNetworkHTTP)
        )
    }

    /// localhost 以外へ送信する設定かどうか（設定画面での注意表示用）
    nonisolated static func isRemote(baseURL: String) -> Bool {
        guard let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
              !host.isEmpty
        else { return false }
        return !OpenAICompatibleClient.isLoopback(host)
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
