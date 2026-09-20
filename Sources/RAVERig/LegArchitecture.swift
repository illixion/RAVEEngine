import Foundation
import simd

/// How a leg meets the ground.
///
/// It matters because almost everything downstream assumes one or the other
/// without saying so. A plantigrade leg's ankle IS its ground contact, so
/// "the foot" is unambiguous. A digitigrade leg stands on its toes with the
/// ankle carried high — what looks like a backward-bending knee is the
/// ankle — so the joint named "foot" is nowhere near the floor, and code
/// that plants it, measures its speed, or aims IK at it is off by a whole
/// segment.
///
/// User content will be both. Anthro and creature characters are routinely
/// digitigrade, and a pipeline that only handles human legs silently does the
/// wrong thing rather than refusing, which is worse.
public enum LegArchitecture: String, Sendable, Codable, Equatable {
    case plantigrade
    case digitigrade
}

/// What one leg is, measured from its rest pose.
public struct LegProfile: Sendable, Equatable {
    public var architecture: LegArchitecture
    /// Joint that meets the floor — what a foot plant holds still, and whose
    /// backward slide past the hips is the character's ground speed.
    public var groundContact: Int
    /// The joint above the ground contact: a plantigrade leg's ankle, a
    /// digitigrade leg's raised hock. What an IK chain bends toward.
    public var ankle: Int
    /// Hip to ground contact, summed along the chain.
    public var legLength: Float
    /// How far the ankle sits above the ground contact, over leg length.
    /// This is the measurement the classification is made from.
    public var ankleLift: Float

    public init(architecture: LegArchitecture, groundContact: Int, ankle: Int,
                legLength: Float, ankleLift: Float) {
        self.architecture = architecture
        self.groundContact = groundContact
        self.ankle = ankle
        self.legLength = legLength
        self.ankleLift = ankleLift
    }
}

extension LegArchitecture {

    /// Above this fraction of leg length, an ankle is carried rather than
    /// planted. Measured: Mixamo's human leg lifts its ankle 0.08 of a leg,
    /// the Synth's lifts it 0.36. Anything in between is a stylised human or
    /// a shallow digitigrade, and either reading behaves sensibly — the
    /// ground contact is chosen by height, not by this number.
    public static let digitigradeThreshold: Float = 0.18

    /// Classifies one leg chain from its rest pose.
    ///
    /// Works off heights rather than names. A rig may call its joints
    /// anything at all — `Def_Digi_Foot_L`, `hock`, `bone_042` — and user
    /// content reliably does, so the only dependable signal is where the
    /// joints actually sit when the character stands.
    public static func profile(ofLeg chain: [Int], in rig: RigSkeleton) -> LegProfile? {
        guard chain.count >= 2 else { return nil }
        func head(_ i: Int) -> SIMD3<Float> { rig.joints[i].restHead }
        // The floor is whatever sits lowest, which is the toe on a digitigrade
        // leg and the heel or toe on a plantigrade one.
        guard let groundContact = chain.min(by: { head($0).y < head($1).y }) else { return nil }
        let position = chain.firstIndex(of: groundContact) ?? chain.count - 1
        let ankle = position > 0 ? chain[position - 1] : groundContact

        var legLength: Float = 0
        for (a, b) in zip(chain, chain.dropFirst()) { legLength += simd_length(head(b) - head(a)) }
        // A chain measured as a straight line would read a bent digitigrade
        // leg as short; summing the segments is the length the leg can reach.
        guard legLength > 1e-4 else { return nil }

        let lift = (head(ankle).y - head(groundContact).y) / legLength
        return LegProfile(
            architecture: lift > digitigradeThreshold ? .digitigrade : .plantigrade,
            groundContact: groundContact, ankle: ankle,
            legLength: legLength, ankleLift: lift)
    }

    /// Both legs, when both can be read. Falls back to whichever side exists.
    public static func profiles(landmarks: HumanoidLandmarks,
                                rig: RigSkeleton) -> (left: LegProfile, right: LegProfile)? {
        guard let left = profile(ofLeg: landmarks.leftLeg, in: rig),
              let right = profile(ofLeg: landmarks.rightLeg, in: rig) else { return nil }
        return (left, right)
    }
}
