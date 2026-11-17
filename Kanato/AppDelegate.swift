//
//  AppDelegate.swift
//  Kanato
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApplication.servicesProvider は強参照を保証しないため、ここで所有する。
    private lazy var serviceProvider = KanaServiceProvider(onSetupRequired: { [weak self] in
        self?.showSettings()
    })

    /// 設定ウィンドウを開く処理（SwiftUI の openWindow）。KanatoApp が登録する
    var openSettingsWindow: (() -> Void)?

    /// モデル未ダウンロードなどで変換できないとき、設定画面を前面に出して案内する
    func showSettings() {
        openSettingsWindow?()
        NSApplication.shared.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = serviceProvider
        // Info.plist の NSServices 変更をシステムに即時反映させる
        NSUpdateDynamicServices()
    }

    /// サービス呼び出しをウォームスタートで受けられるよう、ウィンドウを閉じても常駐する。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
