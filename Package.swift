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
        .library(name: "RAVERig", targets: ["RAVERig"]),
        .library(name: "RAVEHolo", targets: ["RAVEHolo"]),
        .library(name: "RAVEPanel", targets: ["RAVEPanel"]),
    ],
    targets: [
        .target(name: "RAVEInput"),
        .testTarget(name: "RAVEInputTests", dependencies: ["RAVEInput"]),
        .target(name: "RAVEDiagnostics"),
        .testTarget(name: "RAVEDiagnosticsTests", dependencies: ["RAVEDiagnostics"]),
        // Skeleton geometry and IK. Framework-free like the sensing core, and
        // for a sharper reason: its two consumers share nothing but the maths.
        // One drives a RealityKit SkeletalPose, the other a GoldSrc bone
        // palette bound for a Metal vertex shader, so anything that cannot be
        // written without naming a framework belongs in that app's adapter.
        .target(name: "RAVERig"),
        .testTarget(name: "RAVERigTests", dependencies: ["RAVERig"]),
        // In-world holographic UI: panels, gauges and SDF text drawn in Metal
        // into a pass the host app owns (Compositor Services has no RealityKit,
        // so this is how an immersive Metal app gets hand- and object-anchored
        // readouts). Layout and the glyph atlas are CPU-side and host-tested;
        // the renderer compiles its shader source at runtime.
        // Depends on RAVEInput for the palm anchor alone (`RAVEPalmAnchor`,
        // re-exported under its old name); the renderer and layout name no
        // input type.
        .target(name: "RAVEHolo", dependencies: ["RAVEInput"]),
        .testTarget(name: "RAVEHoloTests", dependencies: ["RAVEHolo", "RAVEInput"]),
        // Any SwiftUI view as a panel in a RealityKit scene: its chrome, the
        // attachment hosting fix, placing it in the world, over a palm or
        // ahead of the viewer, and whether anyone can see it. The RealityKit
        // counterpart of RAVEHolo, sharing its palm anchor (so the
        // placement maths exists once for Metal and RealityKit hosts). It
        // lives in RAVEInput, not RAVEHolo: RAVEHolo's Metal 4 renderer does
        // not build for the visionOS simulator. The
        // rules are framework-free and host-tested; the entity half is
        // visionOS-only. Content-agnostic: never imports RAVESDK.
        .target(name: "RAVEPanel", dependencies: ["RAVEInput"]),
        .testTarget(name: "RAVEPanelTests", dependencies: ["RAVEPanel"]),
    ]
)
