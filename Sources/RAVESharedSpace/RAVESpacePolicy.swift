//
//  RAVESpacePolicy.swift
//  RAVESharedSpace
//
//  The settings a space has once for everyone in it. visionOS gives an
//  immersive space one immersion style, one upper-limb visibility and one
//  surroundings effect, and each app used to set them as if it were alone:
//  Longwave hides the arms for PCVR, Hypnos's Cinema darkens the room,
//  spatial-ai-character's Perform goes full. In one shared space somebody has
//  to decide, and this is the rule, kept free of SwiftUI so it can be tested.
//

import Foundation

public enum RAVESpaceImmersion: String, Sendable, Codable {
    case mixed, full
}

/// What the room looks like around the space's content: SwiftUI's `SurroundingsEffect`,
/// as plain values so the policy stays framework-free and testable.
public enum RAVESpaceSurroundings: Sendable, Equatable, Codable {
    /// The system's dark room (`.systemDark`), Hypnos's Cinema.
    case systemDark
    /// The passthrough dimmed by `intensity` 0…1 (`.dim(intensity:)`).
    case dim(intensity: Double)
    /// The three fixed darkenings (`.semiDark`, `.dark`, `.ultraDark`), spatial-ai-character's filters.
    case semiDark, dark, ultraDark
    /// The passthrough multiplied by a colour (`.colorMultiply`), spatial-ai-character's
    /// tints; components may exceed 1 to brighten a channel.
    case tint(red: Double, green: Double, blue: Double)
}

/// What a module asks of the shared space while it is in it.
public struct RAVESpaceRequirements: Sendable, Equatable, Codable {
    public var immersion: RAVESpaceImmersion
    public var hidesUpperLimbs: Bool
    public var surroundings: RAVESpaceSurroundings?
    /// The module reads hands from the host's ARKit session.
    public var needsHands: Bool

    public init(immersion: RAVESpaceImmersion = .mixed, hidesUpperLimbs: Bool = false,
                surroundings: RAVESpaceSurroundings? = nil, needsHands: Bool = false) {
        self.immersion = immersion
        self.hidesUpperLimbs = hidesUpperLimbs
        self.surroundings = surroundings
        self.needsHands = needsHands
    }
}

/// What the space is set to, given everyone in it.
public struct RAVESpaceResolution: Sendable, Equatable {
    public var immersion: RAVESpaceImmersion
    public var upperLimbsHidden: Bool
    public var surroundings: RAVESpaceSurroundings?
    public var needsHands: Bool
    /// Module ids in the space, oldest request first.
    public var members: [String]
}

public enum RAVESpacePolicy {
    /// - Parameter requests: oldest first. A module that asks again moves to the end.
    /// - Returns: nil when nobody wants the space, which closes it.
    ///
    /// The rules:
    /// - **Immersion follows the newest request.** The module the person opened last is the
    ///   one they're looking at; going full for an older one would black out the newer one's
    ///   room-placed content without them having asked.
    /// - **Arms are hidden if anyone hides them.** The reason to hide them (Longwave's PCVR
    ///   titles draw their own hands, Perform's body stands in for them) is a second pair
    ///   misaligned over the first, and that is wrong for everyone in the space.
    /// - **Surroundings follow the newest module that has a preference**, so leaving the
    ///   cinema doesn't leave the room dark for the character.
    /// - **Hand tracking runs if anyone needs it**; it's one session for all of them.
    public static func resolve(_ requests: [(id: String, requirements: RAVESpaceRequirements)]) -> RAVESpaceResolution? {
        guard let newest = requests.last else { return nil }
        return RAVESpaceResolution(
            immersion: newest.requirements.immersion,
            upperLimbsHidden: requests.contains { $0.requirements.hidesUpperLimbs },
            surroundings: requests.last { $0.requirements.surroundings != nil }?.requirements.surroundings,
            needsHands: requests.contains { $0.requirements.needsHands },
            members: requests.map(\.id))
    }
}
