// swift-tools-version: 6.0
import PackageDescription

/// Platform-independent logic shared by the Switchboard app and its extensions.
/// Everything in here is pure Swift + Foundation so it can be unit tested with
/// `swift test` on macOS (and most of it on Linux).
let package = Package(
    name: "SwitchboardKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SwitchboardCore", targets: ["SwitchboardCore"]),
        .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
        .library(name: "ShieldCore", targets: ["ShieldCore"]),
        .library(name: "LocalSendCore", targets: ["LocalSendCore"]),
    ],
    targets: [
        .target(name: "SwitchboardCore"),
        .target(name: "ClipboardCore", dependencies: ["SwitchboardCore"]),
        .target(name: "ShieldCore"),
        .target(name: "LocalSendCore"),
        .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ShieldCoreTests", dependencies: ["ShieldCore"]),
        .testTarget(name: "LocalSendCoreTests", dependencies: ["LocalSendCore"]),
    ],
    swiftLanguageModes: [.v5]
)
