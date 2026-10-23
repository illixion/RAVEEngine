import GameController
import Testing
import simd
@testable import RAVEInput

/// `GCController.withExtendedGamepad()` is a snapshot controller whose elements
/// take values directly, so the capture runs against GameController's own types.
@Suite("Gamepad snapshot")
@MainActor
struct RAVEGamepadSnapshotTests {

    @Test("A resting pad reads as neutral")
    func resting() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        #expect(RAVEGamepadSnapshot(pad) == .neutral)
    }

    @Test("Every button lands on its own bit")
    func buttons() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        let cases: [(GCControllerButtonInput?, RAVEGamepadSnapshot.Buttons)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftTrigger, .leftTrigger), (pad.rightTrigger, .rightTrigger),
            (pad.leftThumbstickButton, .leftStick), (pad.rightThumbstickButton, .rightStick),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options), (pad.buttonHome, .home),
        ]
        for (element, expected) in cases {
            let element = try #require(element)
            element.setValue(1)
            #expect(RAVEGamepadSnapshot(pad).buttons == expected)
            element.setValue(0)
        }
        #expect(RAVEGamepadSnapshot(pad).buttons.isEmpty)
    }

    @Test("D-pad directions map to their bits")
    func dpad() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        pad.dpad.setValueForXAxis(-1, yAxis: 1)
        #expect(RAVEGamepadSnapshot(pad).buttons == [.dpadLeft, .dpadUp])
        pad.dpad.setValueForXAxis(1, yAxis: -1)
        #expect(RAVEGamepadSnapshot(pad).buttons == [.dpadRight, .dpadDown])
    }

    @Test("Sticks and triggers keep their analog values, +Y up")
    func analog() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        pad.leftThumbstick.setValueForXAxis(0.25, yAxis: 0.75)
        pad.rightThumbstick.setValueForXAxis(-0.5, yAxis: -1)
        pad.leftTrigger.setValue(0.4)
        pad.rightTrigger.setValue(1)
        let snapshot = RAVEGamepadSnapshot(pad)
        #expect(simd_distance(snapshot.leftStick, SIMD2(0.25, 0.75)) < 1e-5)
        #expect(simd_distance(snapshot.rightStick, SIMD2(-0.5, -1)) < 1e-5)
        #expect(abs(snapshot.leftTrigger - 0.4) < 1e-5)
        #expect(snapshot.rightTrigger == 1)
        #expect(snapshot.buttons.contains(.rightTrigger))
    }

    @Test("No motion object means no motion, not a still pad")
    func noMotion() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        let snapshot = RAVEGamepadSnapshot(pad, motion: nil)
        #expect(snapshot.rotationRate == nil)
        #expect(snapshot.acceleration == nil)
    }
}
