import Foundation

/// A skeleton as a flat, parent-indexed joint list in **RealityKit space**:
/// Y-up, metres, -Z forward.
///
/// This is the single input to every analysis in this package. It is produced
/// two ways and the two must agree:
///
///   - `scripts/blender-export-humanoid.py` writes it as `rig.json` next to the
///     USDZ it exports, so the importer can reason about a rig without loading
///     RealityKit (which cannot retarget below macOS 27 anyway).
///   - `CharacterKitRealityKit` builds it from a loaded `MeshResource.Skeleton`.
///
/// Joint names are already USD-sanitised (`Def_Index_1.L` → `Def_Index_1_L`),
/// because that is what RealityKit will report and a name that only matches
/// before sanitisation is a name that silently matches nothing.
public struct RigSkeleton: Codable, Sendable, Equatable {

    public struct Joint: Codable, Sendable, Equatable {
        /// Leaf name, USD-sanitised. Unique within a skeleton.
        public var name: String
        /// Index into `joints`, or nil for the single root.
        public var parent: Int?
        /// Rest-pose position of the joint itself, in model space.
        public var restHead: SIMD3<Float>
        /// Rest-pose position of the joint's far end. Blender gives this
        /// directly; a skeleton reconstructed from RealityKit infers it from
        /// the first child, and leaves it nil for childless leaves.
        public var restTail: SIMD3<Float>?
        /// How many mesh vertices this joint actually moves. The single most
        /// useful signal for telling a limb from an ornament — Synth's unused
        /// plantigrade leg chain is a full-length leg carrying no weight.
        public var weightedVertices: Int

        public init(name: String,
                    parent: Int?,
                    restHead: SIMD3<Float>,
                    restTail: SIMD3<Float>? = nil,
                    weightedVertices: Int = 0) {
            self.name = name
            self.parent = parent
            self.restHead = restHead
            self.restTail = restTail
            self.weightedVertices = weightedVertices
        }
    }

    public var joints: [Joint]
    /// Axis-aligned bounds of the skinned meshes, model space. Measured from
    /// geometry, not from the joints — a rig's topmost bone is rarely the top
    /// of the head, and never the top of the hair.
    public var meshBoundsMin: SIMD3<Float>
    public var meshBoundsMax: SIMD3<Float>

    public init(joints: [Joint],
                meshBoundsMin: SIMD3<Float> = .zero,
                meshBoundsMax: SIMD3<Float> = .zero) {
        self.joints = joints
        self.meshBoundsMin = meshBoundsMin
        self.meshBoundsMax = meshBoundsMax
    }

    // MARK: - Topology

    public var rootIndex: Int? {
        joints.firstIndex { $0.parent == nil }
    }

    /// Child indices per joint, in declaration order.
    public var childIndices: [[Int]] {
        var result = [[Int]](repeating: [], count: joints.count)
        for (i, joint) in joints.enumerated() {
            if let p = joint.parent, p >= 0, p < joints.count { result[p].append(i) }
        }
        return result
    }

    public func index(ofJointNamed name: String) -> Int? {
        joints.firstIndex { $0.name == name }
    }

    /// `index` and every joint beneath it.
    public func subtree(from index: Int) -> [Int] {
        let children = childIndices
        var out: [Int] = []
        var stack = [index]
        while let i = stack.popLast() {
            out.append(i)
            stack.append(contentsOf: children[i])
        }
        return out
    }

    /// `index` and every joint above it, root last.
    public func ancestors(of index: Int) -> [Int] {
        var out: [Int] = []
        var cursor: Int? = index
        while let i = cursor {
            out.append(i)
            cursor = joints[i].parent
        }
        return out
    }

    /// Total vertices moved by a joint and everything beneath it. A branch is
    /// judged by what its whole subtree carries, not by its root alone.
    public func subtreeWeight(from index: Int) -> Int {
        subtree(from: index).reduce(0) { $0 + joints[$1].weightedVertices }
    }

    /// Straight-line distance from `index` to the furthest joint beneath it.
    public func subtreeReach(from index: Int) -> Float {
        let origin = joints[index].restHead
        return subtree(from: index)
            .map { simd_length_squared_f(joints[$0].restHead - origin) }
            .max()
            .map { $0.squareRoot() } ?? 0
    }

    /// Longest chain of joints beneath `index`, by joint count.
    public func subtreeDepth(from index: Int) -> Int {
        let children = childIndices
        func depth(_ i: Int) -> Int {
            1 + (children[i].map(depth).max() ?? 0)
        }
        return depth(index)
    }

    // MARK: - Measurements

    /// Height of the skinned geometry, which is what a character's scale and
    /// collision box should be derived from.
    public var meshHeight: Float { meshBoundsMax.y - meshBoundsMin.y }

    /// Signed distance from the model origin to the lowest geometry. Add it to
    /// a character's Y to stand it on the floor.
    public var groundOffset: Float { -meshBoundsMin.y }
}

/// `simd_length_squared` without importing simd — keeps the module free of
/// any framework so it builds and tests on every platform unchanged.
@inlinable
func simd_length_squared_f(_ v: SIMD3<Float>) -> Float {
    v.x * v.x + v.y * v.y + v.z * v.z
}

@inlinable
func simd_length_f(_ v: SIMD3<Float>) -> Float {
    simd_length_squared_f(v).squareRoot()
}

@inlinable
func simd_normalize_f(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = simd_length_f(v)
    return l > 1e-6 ? v / l : .zero
}

@inlinable
func simd_dot_f(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z
}

/// Angle between two vectors, in degrees. Returns 0 for a zero-length input.
@inlinable
func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let na = simd_normalize_f(a), nb = simd_normalize_f(b)
    if na == .zero || nb == .zero { return 0 }
    return acos(max(-1, min(1, simd_dot_f(na, nb)))) * 180 / .pi
}
