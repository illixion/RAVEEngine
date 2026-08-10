// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RAVEEngine",
    // visionOS is the product focus. macOS is declared for two reasons: the
    // pure sensing/binding logic is deliberately framework-free so `swift test`
    // can run it on the host, and the Engine's stated future is a Mac port.
    // ARKit-backed files guard with `#if os(visionOS)` rather than forcing the
    // whole package to one platform.
    platforms: [.visionOS(.v26), .macOS(.v14)],
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
