// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "moonrise",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "VirtualDisplayObjC",
            path: "Sources/VirtualDisplayObjC",
            publicHeadersPath: "include",
            // 手动 retain/release：CGVirtualDisplay 的销毁就是 release 这一步
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "MoonRiseCore",
            dependencies: ["VirtualDisplayObjC"],
            path: "Sources/MoonRiseCore"
        ),
        .executableTarget(
            name: "MoonRiseBar",
            dependencies: ["MoonRiseCore"],
            path: "Sources/MoonRiseBar"
        ),
        .testTarget(
            name: "MoonRiseCoreTests",
            dependencies: ["MoonRiseCore"],
            path: "Tests/MoonRiseCoreTests"
        )
    ]
)
