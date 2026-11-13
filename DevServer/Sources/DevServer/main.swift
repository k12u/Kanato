//
//  main.swift
//  DevServer
//
//  開発・テスト専用の OpenAI 互換 Mock LLM Server のエントリーポイント。
//

import Foundation

// Xcode のコンソールやパイプ経由でもすぐ表示されるよう、標準出力をバッファリングしない
setvbuf(stdout, nil, _IONBF, 0)

let configuration: ServerConfiguration
do {
    configuration = try ServerConfiguration.fromEnvironment(ProcessInfo.processInfo.environment)
} catch {
    FileHandle.standardError.write(Data("DevServer: invalid configuration: \(error)\n".utf8))
    exit(64)
}

print("""
    KanaFilter DevServer (development only)
      Listen:  \(configuration.host):\(configuration.port)
      BaseURL: http://\(configuration.host):\(configuration.port)/v1
      Model:   \(ServerConfiguration.modelID)
      Mode:    \(configuration.mode.rawValue)
      Delay:   \(configuration.delayMilliseconds) ms
    """)
if !configuration.isLoopback {
    print("WARNING: listening on a non-loopback address without authentication.")
}

let app = MockLLMServer(configuration: configuration).buildApplication {
    print("DevServer is running. Press Ctrl+C (or Stop in Xcode) to quit.")
}
try await app.runService()
