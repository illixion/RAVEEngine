import Testing
import simd
@testable import RAVERig

private func turn(_ degrees: Float) -> JointPose {
    JointPose(rotation: simd_quatf(angle: degrees * .pi / 180, axis: [0, 0, 1]))
}

private func degrees(_ pose: JointPose) -> Float {
    pose.rotation.angle * 180 / .pi * (pose.rotation.axis.z < 0 ? -1 : 1)
}

/// One joint turning 0°, 30°, 60° at a tenth of a second per frame.
private func ramp(loops: Bool) -> PoseClip {
    PoseClip(frames: [[turn(0)], [turn(30)], [turn(60)]], frameInterval: 0.1, loops: loops)
}

@Test func samplesBetweenFrames() {
    let clip = ramp(loops: false)
    #expect(abs(degrees(clip.sample(at: 0.05)[0]) - 15) < 0.01)
    #expect(abs(degrees(clip.sample(at: 0.15)[0]) - 45) < 0.01)
}

@Test func aClipThatPlaysOnceHoldsItsLastFrame() {
    let clip = ramp(loops: false)
    #expect(abs(clip.duration - 0.2) < 1e-6)
    #expect(abs(degrees(clip.sample(at: 5)[0]) - 60) < 0.01)
    #expect(clip.isFinished(at: 0.2))
    #expect(!clip.isFinished(at: 0.19))
}

@Test func aLoopStepsFromItsLastFrameBackToItsFirst() {
    let clip = ramp(loops: true)
    // Three frames looping take three intervals, the last one heading home.
    #expect(abs(clip.duration - 0.3) < 1e-6)
    #expect(abs(degrees(clip.sample(at: 0.25)[0]) - 30) < 0.01, "halfway from 60° back to 0°")
    #expect(abs(degrees(clip.sample(at: 0.35)[0]) - 15) < 0.01, "wraps into the next pass")
    #expect(abs(degrees(clip.sample(at: -0.05)[0]) - 30) < 0.01, "negative time wraps too")
    #expect(!clip.isFinished(at: 100))
}

@Test func mixingTakesTheShortArc() {
    // The same 10° turn, written once with a negated quaternion.
    let a = turn(0)
    var b = turn(10)
    b.rotation = simd_quatf(vector: -b.rotation.vector)
    let half = JointPose.mix(a, b, 0.5)
    #expect(abs(abs(degrees(half)) - 5) < 0.01)
}

@Test func playerCrossfadesFromWhatWasShowing() {
    let still = PoseClip(frames: [[turn(0)]], frameInterval: 0.1, loops: true)
    let tilted = PoseClip(frames: [[turn(90)]], frameInterval: 0.1, loops: true)
    var player = PosePlayer()
    player.play(still, fade: 0.3)
    #expect(!player.isFading, "the first clip cuts in")
    #expect(abs(degrees(player.advance(0.1)[0])) < 0.01)

    player.play(tilted, fade: 0.2)
    let midway = degrees(player.advance(0.1)[0])
    #expect(abs(midway - 45) < 0.5, "smoothstep is half way at half time")
    #expect(player.isFading)
    #expect(abs(degrees(player.advance(0.1)[0]) - 90) < 0.01)
    #expect(!player.isFading)
}

@Test func aChangeDuringAChangeStartsFromThePoseOnScreen() {
    let a = PoseClip(frames: [[turn(0)]], frameInterval: 0.1, loops: true)
    let b = PoseClip(frames: [[turn(90)]], frameInterval: 0.1, loops: true)
    var player = PosePlayer()
    player.play(a, fade: 0)
    _ = player.advance(0.016)
    player.play(b, fade: 0.2)
    let shown = degrees(player.advance(0.1)[0])
    // Back to `a` half way through: the first frame of the new fade must be
    // close to what was just shown, not to `b` or to `a`.
    player.play(a, fade: 0.2)
    let next = degrees(player.advance(0.001)[0])
    #expect(abs(next - shown) < 1, "no jump: \(shown)° then \(next)°")
}

@Test func playerReportsAOneShotEnding() {
    var player = PosePlayer()
    player.play(ramp(loops: false), fade: 0)
    _ = player.advance(0.1)
    #expect(!player.isFinished)
    _ = player.advance(0.15)
    #expect(player.isFinished)
}
