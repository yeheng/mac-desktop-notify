// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacDesktopNotify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDesktopNotify", targets: ["MacDesktopNotify"])
    ],
    dependencies: [
        // Pinned to the exact revision this app was built and verified against.
        // `branch: "main"` meant any `swift package update` could silently change
        // rendering: the kit's floating style went from a rounded rectangle
        // (tag 1.1.0) to a `Capsule` clip, which is what put pale wedges in the
        // notch panel's corners on displays without a notch. A revision cannot
        // drift, and the one place that depends on the floating path is already
        // forced to the notch style on purpose (see `NotchPresenter.makeNotch`).
        .package(
            url: "https://github.com/yeheng/DynamicNotchKit",
            revision: "46c2af215639941184b30b277c18bfc3dddba291"
        )
    ],
    targets: [
        .executableTarget(
            name: "MacDesktopNotify",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            path: "Sources/MacDesktopNotify"
        ),
        .testTarget(
            name: "MacDesktopNotifyTests",
            dependencies: ["MacDesktopNotify"],
            path: "Tests/MacDesktopNotifyTests"
        )
    ]
)
