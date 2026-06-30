// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacDesktopNotify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDesktopNotify", targets: ["MacDesktopNotify"]),
        .executable(name: "mac-notify", targets: ["MacNotifyCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.3.0")
    ],
    targets: [
        .target(
            name: "IslandAnimationCore",
            path: "Sources/IslandAnimationCore"
        ),
        .testTarget(
            name: "IslandAnimationCoreTests",
            dependencies: ["IslandAnimationCore"],
            path: "Tests/IslandAnimationCoreTests"
        ),
        .testTarget(
            name: "MacDesktopNotifyTests",
            dependencies: ["MacDesktopNotify"],
            path: "Tests/MacDesktopNotifyTests"
        ),
        .executableTarget(
            name: "MacDesktopNotify",
            dependencies: [
                "IslandAnimationCore",
                .product(name: "Swifter", package: "swifter"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/MacDesktopNotify",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "MacNotifyCLI",
            path: "Sources/MacNotifyCLI"
        )
    ]
)
