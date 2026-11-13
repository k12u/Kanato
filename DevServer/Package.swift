// swift-tools-version: 6.0
// 開発・テスト専用の OpenAI 互換 Mock LLM Server。
// Kanato.app のターゲットからは参照しないため、アプリのバンドルには含まれない。

import PackageDescription

let package = Package(
    name: "DevServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DevServer", targets: ["DevServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
    ],
    targets: [
        .executableTarget(
            name: "DevServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "DevServerTests",
            dependencies: [
                "DevServer",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
