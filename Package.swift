// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WebHub",
    platforms: [.macOS(.v14)],
    products: [
        // 宿主：应用中心 + 所有站点窗口都活在这个进程里
        .executable(name: "WebHub", targets: ["WebHub"]),
        // 站点 shim：只占 Dock 位，把开窗请求转发给宿主
        .executable(name: "WebHubRunner", targets: ["WebHubRunner"])
    ],
    targets: [
        // 两侧共享的最小契约，避免 shim 拖进宿主的 AppKit/WebKit 依赖
        .target(name: "WebHubIPC"),
        .executableTarget(
            name: "WebHub",
            dependencies: ["WebHubIPC"],
            resources: [.copy("Resources/launcher.html")]
        ),
        .executableTarget(
            name: "WebHubRunner",
            dependencies: ["WebHubIPC"]
        )
    ]
)
