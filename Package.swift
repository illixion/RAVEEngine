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
        .library(name: "RAVESharedSpace", targets: ["RAVESharedSpace"]),
        .library(name: "RAVEModuleBus", targets: ["RAVEModuleBus"]),
        .library(name: "RAVEFoveatedGaze", targets: ["RAVEFoveatedGaze"]),
    ],
    // The one external dependency: RAVEInput hands its diagnostics over as
    // log messages, so each value keeps its own privacy (a Quest's address and
    // name stay private, calibration numbers public). It links only DebugTrace's
    // small `DebugLog` product (the message type and logger, no dependencies),
    // not the trace builder, registry or server: an app that links DebugTrace
    // gets these lines in its console and traces anyway. DebugTrace links
    // neither RAVE package. See ~/Projects/CLAUDE.md.
    dependencies: [
        .package(path: "../DebugTrace"),
    ],
    targets: [
        .target(name: "RAVEInput", dependencies: [.product(name: "DebugLog", package: "DebugTrace")]),
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
        // Several apps sharing one immersive space as modules of one process
        // (Nexus), since visionOS shows only the space-owning app's windows.
        // The broker opens the space while anyone wants it, the policy settles
        // its single immersion style, arm visibility and surroundings, one
        // ARKit session serves everyone, and each module's content sits under
        // its own root with taps routed back to it. Policy and broker are
        // framework-free and host-tested; the space itself is visionOS-only.
        // Logs through DebugLog like RAVEInput.
        .target(name: "RAVESharedSpace", dependencies: [.product(name: "DebugLog", package: "DebugTrace")]),
        .testTarget(name: "RAVESharedSpaceTests", dependencies: ["RAVESharedSpace"]),
        // The channel between modules in one process (Nexus): typed context feeds a
        // module publishes (what is playing, what was said, where the screen is) and
        // actions it offers (pause, skip), plus the shared media vocabulary, so a
        // companion can watch along without importing the player. Foundation and
        // simd only, host-tested; no dependency on RAVESharedSpace, so any module
        // can link it whether or not it lives in a shared space.
        .target(name: "RAVEModuleBus"),
        .testTarget(name: "RAVEModuleBusTests", dependencies: ["RAVEModuleBus"]),
        // Gaze from Apple's FoveatedStreaming (visionOS 27): the host half
        // (a message-channel receiver, the official provider feed, plug-in
        // discovery) and the extension half (a gaze-only streaming provider
        // an app's extension target subclasses in one line). Its own target so
        // RAVEInput's other consumers never link FoveatedStreaming. Everything
        // sits under `canImport(FoveatedStreaming)`, so it builds empty on
        // macOS and in the simulator. The wire format is RAVEInput's.
        // FoveatedStreaming exists from visionOS 26.4: an app with a lower
        // floor weak-links it itself (`OTHER_LDFLAGS[sdk=xros*] = -weak_framework
        // FoveatedStreaming`, as Longwave does). SwiftPM can't say "device only",
        // and the simulator has no such framework.
        .target(name: "RAVEFoveatedGaze", dependencies: ["RAVEInput", .product(name: "DebugLog", package: "DebugTrace")]),
    ]
)
