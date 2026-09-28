import RAVEInput

/// The palm anchor, under the name Metal hosts know it by. It moved to
/// RAVEInput (`RAVEPalmAnchor`) so RealityKit hosts can share it through
/// RAVEPanel without linking RAVEHolo's renderer.
public typealias RAVEHoloPalmAnchor = RAVEPalmAnchor
