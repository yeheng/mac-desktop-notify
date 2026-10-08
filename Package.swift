// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacDesktopNotify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDesktopNotify", targets: ["MacDesktopNotify"])
    ],
    targets: [
        .executableTarget(
            name: "MacDesktopNotify",
            path: "Sources/MacDesktopNotify",
            // The built-in toast style packs ship inside the app as the presets
            // the picker offers; the tests read them from source as well.
            resources: [
                .copy("Builtin/styles")
            ]
        ),
        .testTarget(
            name: "MacDesktopNotifyTests",
            dependencies: ["MacDesktopNotify"],
            path: "Tests/MacDesktopNotifyTests"
        )
    ]
)
