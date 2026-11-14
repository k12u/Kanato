// swift-tools-version: 6.0
//
// llama.cpp（公式 XCFramework）と、それを使う最小限の Swift ラッパー。
// XCFramework はリリースの URL とチェックサムで固定する。更新時は scripts/check-model-artifacts.sh ではなく
// ここ（url / checksum）と docs/local-models.md を更新する。
// チェックサムは GitHub Release の digest（sha256）と一致することを確認済み。

import PackageDescription

let package = Package(
    name: "LlamaCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LlamaCpp", targets: ["LlamaCpp"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-xcframework.zip",
            checksum: "937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c"
        ),
        .target(name: "LlamaCpp", dependencies: ["llama"]),
        .testTarget(name: "LlamaCppTests", dependencies: ["LlamaCpp"]),
    ]
)
