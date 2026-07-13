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
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.3.0"),
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "IslandAnimationCore",
            path: "Sources/IslandAnimationCore"
        ),
        .target(
            name: "UnixSocketSupport",
            path: "Sources/UnixSocketSupport"
        ),
        .target(
            name: "AtollUI",
            dependencies: ["Defaults"],
            path: "Sources/AtollUI"
        ),
        .target(
            name: "AtollExtensionKit",
            path: "Sources/AtollExtensionKit"
        ),
        .testTarget(
            name: "IslandAnimationCoreTests",
            dependencies: ["IslandAnimationCore"],
            path: "Tests/IslandAnimationCoreTests"
        ),
        .testTarget(
            name: "MacDesktopNotifyTests",
            dependencies: ["MacDesktopNotify", "UnixSocketSupport"],
            path: "Tests/MacDesktopNotifyTests"
        ),
        .executableTarget(
            name: "MacDesktopNotify",
            dependencies: [
                "AtollUI",
                "AtollExtensionKit",
                "IslandAnimationCore",
                "UnixSocketSupport",
                .product(name: "Swifter", package: "swifter"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/MacDesktopNotify",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "MacNotifyCLI",
            dependencies: ["UnixSocketSupport"],
            path: "Sources/MacNotifyCLI"
        )
    ]
)
