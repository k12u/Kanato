//
//  KanaServiceProvider.swift
//  Kanato
//

import AppKit
import os

/// macOS Services の受け口。変換の詳細は持たず、pasteboard の入出力だけを扱う。
final class KanaServiceProvider: NSObject {
    /// NSServices の NSTimeout (15 秒) より短い、完了待ちの絶対上限
    static let maxWait: TimeInterval = 13
    /// HTTP タイムアウトに上乗せする待ち時間（レスポンス検証などの余裕）
    static let waitMargin: TimeInterval = 1.5

    private static let logger = Logger(subsystem: "org.k12u.Kanato", category: "Service")
    private var handledRequestCount = 0

    private let loadConfiguration: () -> LLMConfiguration
    private let makeBackend: (LLMConfiguration) -> any InferenceBackend
    /// モデル未ダウンロードなど、設定画面で解消できる失敗のときに呼ぶ（設定画面を開く）
    private let onSetupRequired: () -> Void

    /// テストでは接続設定と推論バックエンドを差し替える
    init(
        loadConfiguration: @escaping () -> LLMConfiguration = { AppSettings.loadConfiguration() },
        makeBackend: @escaping (LLMConfiguration) -> any InferenceBackend = {
            InferenceBackendFactory().makeBackend(selection: AppSettings.loadBackendSelection(), configuration: $0)
        },
        onSetupRequired: @escaping () -> Void = {}
    ) {
        self.loadConfiguration = loadConfiguration
        self.makeBackend = makeBackend
        self.onSetupRequired = onSetupRequired
        super.init()
    }

    /// Info.plist の NSMessage "convertKana" に対応する (ObjC セレクタ: convertKana:userData:error:)
    @objc(convertKana:userData:error:)
    func convertKana(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let invokedAt = ContinuousClock.now
        logInvocation()

        guard let input = pasteboard.string(forType: .string), !input.isEmpty else {
            fail(ConversionError.emptyInput, error: error)
            return
        }

        let configuration = loadConfiguration()
        let backend = makeBackend(configuration)
        let waitLimit = min(configuration.timeout + Self.waitMargin, Self.maxWait)

        // サービスメソッドは同期 API のため、変換をバックグラウンドで実行して完了を待つ
        let result = BlockingBridge.run(timeout: waitLimit) {
            try await backend.convert(input)
        }

        switch result {
        case .success(let converted):
            // 成功時のみ pasteboard を書き換える
            pasteboard.clearContents()
            if pasteboard.setString(converted, forType: .string) {
                Self.logger.info("Service succeeded in \(ContinuousClock.now - invokedAt, privacy: .public)")
            } else {
                fail(ConversionError.invalidResponse, error: error)
            }
        case .failure(let conversionError):
            Self.logger.error("Service failed after \(ContinuousClock.now - invokedAt, privacy: .public)")
            fail(conversionError, error: error)
            if (conversionError as? InferenceBackendError)?.requiresUserSetup == true {
                // サービスの応答を返してから設定画面を開く（呼び出し元アプリをブロックしない）
                DispatchQueue.main.async(execute: onSetupRequired)
            }
        }
    }

    private func fail(_ failure: any Error, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        Self.logger.error("Service error: \(message, privacy: .public)")
        error.pointee = "Kanato: \(message)" as NSString
        NSSound.beep()
    }

    /// コールドスタート（プロセス起動直後の初回呼び出し）の計測用ログ
    private func logInvocation() {
        handledRequestCount += 1
        if handledRequestCount == 1, let launchDate = NSRunningApplication.current.launchDate {
            let sinceLaunch = Date().timeIntervalSince(launchDate)
            Self.logger.info("Service invoked (cold start, \(sinceLaunch, format: .fixed(precision: 3), privacy: .public)s after launch)")
        } else {
            Self.logger.info("Service invoked (warm, request #\(self.handledRequestCount, privacy: .public))")
        }
    }
}

/// async 処理を同期的に待つブリッジ。
/// 呼び出し元 (メインスレッド) はセマフォで待つだけで、処理自体はメインスレッドに依存しないため
/// MainActor への同期待ちによるデッドロックは起きない。
nonisolated enum BlockingBridge {
    static func run<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) -> Result<T, any Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        let task = Task.detached {
            do {
                box.set(.success(try await operation()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.get() else {
            // タイムアウト後に届いた結果は box に入るだけで、pasteboard には反映されない
            task.cancel()
            return .failure(ConversionError.timeout)
        }
        return result
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, any Error>?

        func set(_ newValue: Result<T, any Error>) {
            lock.withLock { result = newValue }
        }

        func get() -> Result<T, any Error>? {
            lock.withLock { result }
        }
    }
}
