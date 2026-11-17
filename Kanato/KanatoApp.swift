//
//  KanatoApp.swift
//  Kanato
//
//  Created by minoru-kawamoto on 2026/11/13.
//

import SwiftUI

@main
struct KanatoApp: App {
    /// Service Provider は AppDelegate が生成・保持する
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Kanato 設定", id: "settings") {
            SettingsView()
                .modifier(RegisterSettingsOpener(appDelegate: appDelegate))
        }
        .windowResizability(.contentSize)
    }
}

/// AppKit 側（サービス）から設定ウィンドウを開けるよう、openWindow を AppDelegate に渡す
private struct RegisterSettingsOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    func body(content: Content) -> some View {
        content.onAppear {
            appDelegate.openSettingsWindow = { openWindow(id: "settings") }
        }
    }
}
