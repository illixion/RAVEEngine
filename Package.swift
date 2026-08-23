// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RAVEEngine",
    // visionOS is the product focus. macOS is declared for two reasons: the
    // pure sensing/binding logic is deliberately framework-free so `swift test`
    // can run it on the host, and the Engine's stated future is a Mac port.
    // ARKit-backed files guard with `#if os(visionOS)` rather than forcing the
    // whole package to one platform.
    //
    // iOS is declared because an omitted platform is not an excluded one: it
    // gets SwiftPM's own default floor instead, and RAVEDiagnostics then fails
    // to build for an iOS client on `OSSignposter` (iOS 15) and SwiftUI
    // (iOS 13) — floors nothing here has ever targeted.
    platforms: [.visionOS(.v26), .macOS(.v14), .iOS(.v26)],
    products: [
        .library(name: "RAVEInput", targets: ["RAVEInput"]),
        .library(name: "RAVEDiagnostics", targets: ["RAVEDiagnostics"]),
    ],
    targets: [
        .target(name: "RAVEInput"),
        .testTarget(name: "RAVEInputTests", dependencies: ["RAVEInput"]),
        .target(name: "RAVEDiagnostics"),
        .testTarget(name: "RAVEDiagnosticsTests", dependencies: ["RAVEDiagnostics"]),
    ]
)
