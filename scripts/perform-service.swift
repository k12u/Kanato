//
//  perform-service.swift
//  開発用: 起動中の Kanato の「Kanatoで変換」サービスを、実際のサービス経路（NSPerformService）で呼び出す。
//
//    swiftc -module-cache-path /tmp/kanato-swift-mc scripts/perform-service.swift -o /tmp/perform-service
//    /tmp/perform-service 'きょうはいいてんきです'
//
//  専用の pasteboard に入力を置いてサービスを呼び、成否・所要時間・置換後の文字列を表示する。
//  接続先の切り替えは Kanato の起動引数で行う（例）:
//    open -n Kanato.app --args -apiFormat zenz -baseURL http://127.0.0.1:8801/v1
//

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: perform-service <text>\n".utf8))
    exit(64)
}
let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.k12u.Kanato.perform-service.\(UUID().uuidString)"))
defer { pasteboard.releaseGlobally() }
pasteboard.clearContents()
pasteboard.setString(CommandLine.arguments[1], forType: .string)

let start = Date()
let succeeded = NSPerformService("Kanatoで変換", pasteboard)
print("succeeded=\(succeeded) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
print(pasteboard.string(forType: .string) ?? "<nil>")
exit(succeeded ? 0 : 1)
