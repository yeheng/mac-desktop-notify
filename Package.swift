// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacDesktopNotify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDesktopNotify", targets: ["MacDesktopNotify"])
    ],
    targets: [
        // Vendored from https://github.com/yeheng/DynamicNotchKit (MIT, see its
        // LICENSE): upstream `cd0b3e5` plus the fork's pill-radius tuning, with
        // the floating `Capsule` clip reverted. Local patches are marked
        // `local patch:` in the sources. Owned here on purpose - the kit's API
        // is too narrow for what the app needs to ask it (see IslandGeometry).
        .target(
            name: "DynamicNotchKit",
            path: "Sources/DynamicNotchKit"
        ),
        .executableTarget(
            name: "MacDesktopNotify",
            dependencies: ["DynamicNotchKit"],
            path: "Sources/MacDesktopNotify"
        ),
        .testTarget(
            name: "MacDesktopNotifyTests",
            dependencies: ["MacDesktopNotify"],
            path: "Tests/MacDesktopNotifyTests"
        )
    ]
)
