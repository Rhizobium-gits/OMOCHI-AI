// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OmochiAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OmochiAI",
            path: "Sources/OmochiAI",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        // 画面や claude を使わない部分（設定の読み込み・判定ロジック）のテスト。`swift test` で実行（Xcode 不要）
        .testTarget(
            name: "OmochiAITests",
            dependencies: ["OmochiAI"],
            path: "Tests/OmochiAITests"
        ),
    ]
)
