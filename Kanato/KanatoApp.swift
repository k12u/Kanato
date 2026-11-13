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
        }
        .windowResizability(.contentSize)
    }
}
