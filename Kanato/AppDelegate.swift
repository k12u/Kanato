//
//  AppDelegate.swift
//  Kanato
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApplication.servicesProvider は強参照を保証しないため、ここで所有する。
    private let serviceProvider = KanaServiceProvider()

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
