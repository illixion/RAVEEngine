import Foundation
import Testing
import simd
@testable import RAVEPanel

/// The panel rules the apps pause and place by: the view test and its
/// hysteresis (spatial-ai-character's screen, measured behaviour), the head
/// follow (Longwave's banner) and the drag gain.
@Suite struct RAVEPanelRulesTests {
    let viewer = RAVEPanelViewer(position: [0, 1.6, 0], forward: [0, 0, -1])
    let size = SIMD2<Float>(1.2, 0.75)

    @Test func viewerFromDeviceTransformLooksAlongMinusZ() {
        var m = matrix_identity_float4x4
        m.columns.3 = [1, 1.5, 2, 1]
        let v = RAVEPanelViewer(transform: m)
        #expect(v.position == [1, 1.5, 2])
        #expect(simd_distance(v.forward, [0, 0, -1]) < 1e-6)
    }

    @Test func inViewCountsTheEdgeNotJustTheCentre() {
        // Centre 70° off the gaze, 1.5 m away: out by the centre, but a 4 m
        // wide panel reaches back inside the 60° cone.
        let angle: Float = 70 * .pi / 180
        let center = viewer.position + SIMD3(sin(angle), 0, -cos(angle)) * 1.5
        #expect(!RAVEPanelVisibility.isInView(center: center, size: [0.3, 0.2], of: viewer, halfAngle: .pi / 3))
        #expect(RAVEPanelVisibility.isInView(center: center, size: [4, 2], of: viewer, halfAngle: .pi / 3))
        #expect(!RAVEPanelVisibility.isInView(center: [0, 1.6, 2], size: size, of: viewer, halfAngle: .pi / 3))
    }

    @Test func pausesOnlyAfterTheDelayAndResumesAtOnce() {
        var v = RAVEPanelVisibility()
        let ahead = SIMD3<Float>(0, 1.6, -1.5), behind = SIMD3<Float>(0, 1.6, 1.5)
        do { let r = v.update(available: true, center: ahead, size: size, viewer: viewer, now: 0); #expect(r) }
        // The delay runs from the last moment it was seen (0).
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 1); #expect(r) }
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 1.4); #expect(r) }
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 1.6); #expect(!r) }
        do { let r = v.update(available: true, center: ahead, size: size, viewer: viewer, now: 1.7); #expect(r) }
    }

    @Test func unavailableStopsAtOnceAndShowingAgainRuns() {
        var v = RAVEPanelVisibility()
        let behind = SIMD3<Float>(0, 1.6, 1.5)
        do { let r = v.update(available: false, center: behind, size: size, viewer: viewer, now: 0); #expect(!r) }
        // Shown again out of view: runs, then pauses after the delay.
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 1); #expect(r) }
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 2.4); #expect(r) }
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 2.6); #expect(!r) }
    }

    @Test func keepAwakeHoldsItRunningUnseenButNotUnavailable() {
        var v = RAVEPanelVisibility()
        let behind = SIMD3<Float>(0, 1.6, 1.5)
        v.update(available: true, center: behind, size: size, viewer: viewer, now: 0)
        v.keepAwake(until: 10)
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 5); #expect(r) }
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 9.9); #expect(r) }
        // Awake ended at 10; the delay runs from the last awake frame.
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 11); #expect(r) }
        do { let r = v.update(available: true, center: behind, size: size, viewer: viewer, now: 11.5); #expect(!r) }
        v.keepAwake(until: 20)
        do { let r = v.update(available: false, center: behind, size: size, viewer: viewer, now: 13); #expect(!r) }
    }

    @Test func noViewerCountsAsSeen() {
        var v = RAVEPanelVisibility()
        do { let r = v.update(available: true, center: [0, 0, 5], size: size, viewer: nil, now: 0); #expect(r) }
        do { let r = v.update(available: true, center: [0, 0, 5], size: size, viewer: nil, now: 100); #expect(r) }
    }

    @Test func facingPutsPlusZTowardTheViewerAndStaysUpright() {
        let q = RAVEPanelOrientation.facing(from: [0.3, 1.0, -0.4], toward: [0, 1.6, 0])
        let z = q.act([0, 0, 1]), x = q.act([1, 0, 0])
        let want = simd_normalize(SIMD3<Float>(-0.3, 0.6, 0.4))
        #expect(simd_distance(z, want) < 1e-5)
        #expect(abs(x.y) < 1e-5)   // no roll
        let turned = RAVEPanelOrientation.turned(from: [0.3, 1.0, -0.4], toward: [0, 1.6, 0]).act([0, 0, 1])
        #expect(abs(turned.y) < 1e-5)
    }

    @Test func headFollowAppearsAheadThenTrailsATurn() {
        var follow = RAVEPanelHeadFollow(distance: 1.5, drop: 0.28, smoothing: 1.2)
        do { let r = follow.update(viewer: nil, deltaTime: 0.1); #expect(r == nil) }
        let first = follow.update(viewer: viewer, deltaTime: 0.1)!
        #expect(simd_distance(first.position, [0, 1.32, -1.5]) < 1e-5)
        #expect(simd_distance(first.orientation.act([0, 0, 1]), [0, 0, 1]) < 1e-5)
        // Turn to face +x: a tenth of a second later it has barely moved.
        let turned = RAVEPanelViewer(position: [0, 1.6, 0], forward: [1, 0, 0])
        let next = follow.update(viewer: turned, deltaTime: 0.1)!
        #expect(simd_distance(next.position, first.position) < 0.2)
        // Given long enough it is in front again.
        var last = next
        for _ in 0..<100 { last = follow.update(viewer: turned, deltaTime: 0.1)! }
        #expect(simd_distance(last.position, [1.5, 1.32, 0]) < 0.01)
        // Lost tracking keeps the pose; reset forgets it.
        do { let r = follow.update(viewer: nil, deltaTime: 0.1); #expect(r?.position == last.position) }
        follow.reset()
        do { let r = follow.update(viewer: nil, deltaTime: 0.1); #expect(r == nil) }
    }

    @Test func dragGainScalesWithDistance() {
        #expect(RAVEPanelDrag.gain(distance: 0.3) == 1)
        #expect(RAVEPanelDrag.gain(distance: 1.5) == 3)
        #expect(RAVEPanelDrag.gain(distance: 10) == 4)
    }
}

/// The wrist mount and the view lock (Longwave's pinned web panels).
@Suite struct RAVEPanelMountTests {
    /// A left forearm held across the body in front of the chest, back of the
    /// hand up, fingers pointing right: the pose in OVR Toolkit's pictures.
    let palm = RAVEPanelPalm(position: [0, 1.2, -0.4], normalOut: [0, -1, 0], fingers: [1, 0, 0])
    let eye = SIMD3<Float>(0, 1.6, 0)

    @Test func backOfWristSitsAboveTheForearm() {
        let mount = RAVEPanelHandMount()
        let target = mount.target(for: palm)!
        // 5 cm above the back of the hand, 13 cm back toward the elbow.
        #expect(simd_distance(target, [-0.13, 1.25, -0.4]) < 1e-5)
    }

    @Test func offsetRoundTrips() {
        let world = SIMD3<Float>(-0.2, 1.3, -0.35)
        let offset = RAVEPanelHandMount.offset(placing: world, on: palm)!
        var mount = RAVEPanelHandMount(offset: offset)
        #expect(simd_distance(mount.target(for: palm)!, world) < 1e-5)
        _ = mount.update(palm: palm, viewer: eye, deltaTime: 0.1)
        #expect(simd_distance(mount.position!, world) < 1e-5)
    }

    @Test func facesTheViewerWithItsLongEdgeAlongTheArmUpright() {
        var mount = RAVEPanelHandMount()
        let pose = mount.update(palm: palm, viewer: eye, deltaTime: 0.1)!
        let z = pose.orientation.act([0, 0, 1]), x = pose.orientation.act([1, 0, 0]), y = pose.orientation.act([0, 1, 0])
        #expect(simd_dot(z, simd_normalize(eye - pose.position)) > 0.999)
        #expect(abs(x.x) > 0.95)          // along the arm, as the viewer sees it
        #expect(y.y > 0)                  // right way up
        // The right arm points the other way: still upright.
        let right = RAVEPanelPalm(position: [0, 1.2, -0.4], normalOut: [0, -1, 0], fingers: [-1, 0, 0])
        var other = RAVEPanelHandMount()
        let flipped = other.update(palm: right, viewer: eye, deltaTime: 0.1)!
        #expect(flipped.orientation.act([0, 1, 0]).y > 0)
    }

    @Test func hidesWhileThePalmFacesTheViewerAndOnTrackingLoss() {
        var mount = RAVEPanelHandMount(fadeIn: 0.1, fadeOut: 0.1)
        _ = mount.update(palm: palm, viewer: eye, deltaTime: 0.2)
        #expect(mount.opacity == 1)
        let up = RAVEPanelPalm(position: palm.position, normalOut: simd_normalize(eye - palm.position), fingers: [1, 0, 0])
        _ = mount.update(palm: up, viewer: eye, deltaTime: 0.2)
        #expect(mount.opacity == 0)
        _ = mount.update(palm: palm, viewer: eye, deltaTime: 0.2)
        #expect(mount.opacity == 1)
        let stay = mount.position
        _ = mount.update(palm: nil, viewer: eye, deltaTime: 0.2)
        #expect(mount.opacity == 0)
        #expect(mount.position == stay)   // faded where it was
    }

    @Test func headLockHoldsItsPlaceInTheView() {
        var lock = RAVEPanelHeadLock(offset: [0.3, -0.2, -0.9], smoothing: 0)
        var head = matrix_identity_float4x4
        head.columns.3 = [0, 1.6, 0, 1]
        let a = lock.update(head: head, deltaTime: 0.01)!
        #expect(simd_distance(a.position, [0.3, 1.4, -0.9]) < 1e-5)
        #expect(simd_dot(a.orientation.act([0, 0, 1]), simd_normalize(SIMD3(0, 1.6, 0) - a.position)) > 0.999)
        // Turned 90° to the left (looking along -x): the panel went with the view.
        let turn = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        var turned = turn
        turned.columns.3 = head.columns.3
        let b = lock.update(head: turned, deltaTime: 0.01)!
        #expect(simd_distance(b.position, [-0.9, 1.4, -0.3]) < 1e-4)
        #expect(simd_distance(RAVEPanelHeadLock.offset(placing: b.position, head: turned), [0.3, -0.2, -0.9]) < 1e-4)
        do { let r = lock.update(head: nil, deltaTime: 0.01); #expect(r?.position == b.position) }
    }
}
