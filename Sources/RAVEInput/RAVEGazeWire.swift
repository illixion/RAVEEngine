/*
 RAVE Engine — gaze samples as bytes, for any message channel.

 A foveated streaming provider extension and its host app talk over
 `FoveatedStreamingSession` message channels, which carry opaque `Data`.
 This is the payload both sides agree on. It is framework-free so a host
 test, a PC-side tool or a server can read and write it too.

 Layout, little-endian, 44 bytes:

     0  "RG"        magic
     2  u8          version (1)
     3  u8          flags (bit 0: distance is set; bits 1...2: RAVEGazeOrigin)
     4  u64         sequence
     12 f64         provider timestamp, seconds (CACurrentMediaTime on Apple)
     20 f32 x3      direction, head space (-z ahead, +x right, +y up)
     32 f32         distance, metres (0 when unset)
     36 f32 x2      pivot, 0...1, y down

 A decoder accepts a longer message of the same version, so fields can be
 appended without a version bump.
 */

import Foundation
import simd

public enum RAVEGazeWire {

    public static let version: UInt8 = 1
    public static let byteCount = 44
    static let magic: [UInt8] = [0x52, 0x47]

    /// One decoded message: the sample (stamped `receivedAt`) and the
    /// provider's own clock reading.
    public struct Message: Equatable, Sendable {
        public var sample: RAVEGazeSample
        public var providerTime: TimeInterval
    }

    public static func encode(_ sample: RAVEGazeSample, providerTime: TimeInterval) -> Data {
        var out = Data(capacity: byteCount)
        out.append(contentsOf: magic)
        out.append(version)
        out.append((sample.distance == nil ? 0 : 1) | sample.origin.rawValue << 1)
        append(UInt64(clamping: max(0, sample.sequence)), to: &out)
        append(providerTime.bitPattern, to: &out)
        for v in [sample.direction.x, sample.direction.y, sample.direction.z, sample.distance ?? 0,
                  sample.pivot.x, sample.pivot.y] {
            append(v.bitPattern, to: &out)
        }
        return out
    }

    /// Nil for anything that is not a version-1 gaze message.
    public static func decode(_ data: Data, receivedAt: Date = Date()) -> Message? {
        let b = [UInt8](data)
        guard b.count >= byteCount, b[0] == magic[0], b[1] == magic[1], b[2] == version else { return nil }
        let seq = read(UInt64.self, b, 4)
        let time = Double(bitPattern: read(UInt64.self, b, 12))
        guard time.isFinite, time >= 0 else { return nil }
        func f(_ at: Int) -> Float { Float(bitPattern: read(UInt32.self, b, at)) }
        let direction = SIMD3(f(20), f(24), f(28))
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else { return nil }
        let sample = RAVEGazeSample(
            sequence: Int(clamping: seq),
            direction: direction,
            pivot: SIMD2(f(36), f(40)),
            distance: b[3] & 1 == 0 ? nil : f(32),
            receivedAt: receivedAt,
            origin: b[3] & ~0x07 == 0 ? (RAVEGazeOrigin(rawValue: (b[3] >> 1) & 3) ?? .unknown) : .unknown)
        return Message(sample: sample, providerTime: time)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, _ b: [UInt8], _ at: Int) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v |= T(b[at + i]) << (8 * i) }
        return v
    }
}

/// A gaze source a transport pushes into: a message channel, a socket, a test.
public final class RAVEPushGazeSource: RAVEGazeSource, @unchecked Sendable {

    private let lock = NSLock()
    private var sample: RAVEGazeSample?
    private var count = 0

    /// Set by the trusted adapter for a provider channel. This ceiling prevents
    /// a malformed/relayed wire message from granting export permission.
    private let restrictedToProvider: Bool
    public init(restrictedToProvider: Bool = false) { self.restrictedToProvider = restrictedToProvider }

    public var latest: RAVEGazeSample? {
        lock.lock(); defer { lock.unlock() }
        return sample
    }

    /// How many distinct samples have arrived.
    public var received: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Stores `new` unless it repeats the last sequence, so a stalled
    /// provider ages out instead of looking fresh.
    public func push(_ new: RAVEGazeSample) {
        lock.lock(); defer { lock.unlock() }
        var stored = new
        if restrictedToProvider {
            stored = RAVEGazeSample(sequence: new.sequence, direction: new.direction, pivot: new.pivot,
                                    distance: new.distance, receivedAt: new.receivedAt,
                                    localCaptureTime: new.localCaptureTime, origin: .foveatedStreamingProvider)
        }
        if let old = sample, old.sequence == stored.sequence, old.origin == stored.origin { return }
        sample = stored
        count += 1
    }

    /// Decodes and stores one message. Set `usesLocalProviderClock` only for a
    /// provider running on this device with CACurrentMediaTime capture stamps.
    /// A remote provider's clock must not be used as local capture time.
    @discardableResult
    public func ingest(_ data: Data, receivedAt: Date = Date(), usesLocalProviderClock: Bool = false) -> Bool {
        guard let message = RAVEGazeWire.decode(data, receivedAt: receivedAt) else { return false }
        var sample = message.sample
        if usesLocalProviderClock { sample.localCaptureTime = message.providerTime }
        push(sample)
        return true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        sample = nil
    }
}
