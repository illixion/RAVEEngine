/*
 RAVE Engine — memory readings, in the four flavours that actually differ.

 GPU allocation and process footprint answer different questions and are easy
 to confuse. On Apple Silicon they draw on the same physical pool, but only the
 footprint is what jetsam counts, and only the GPU figure moves when you change
 texture compression. Spatial Stash's monitor exists specifically to compare
 lossy against lossless texture storage, which is a GPU-allocation question;
 a footprint reading would have shown it almost nothing.

 `os_proc_available_memory` is the one that matters for staying alive: it is
 headroom before this process is killed, which no ratio of the other two can
 tell you.
 */

import Foundation

#if canImport(Metal)
import Metal
#endif

/// One reading of the memory situation. All values in bytes; nil where the
/// platform or configuration cannot answer.
public struct RAVEMemoryReading: Sendable, Equatable {
    /// `MTLDevice.currentAllocatedSize` — what Metal is holding. Moves with
    /// texture count, resolution and compression mode.
    public var gpuAllocated: Int?
    /// `task_vm_info.phys_footprint` — what jetsam counts against this process.
    public var processFootprint: Int?
    /// `os_proc_available_memory()` — headroom before termination.
    public var availableMemory: Int?

    public init(
        gpuAllocated: Int? = nil,
        processFootprint: Int? = nil,
        availableMemory: Int? = nil
    ) {
        self.gpuAllocated = gpuAllocated
        self.processFootprint = processFootprint
        self.availableMemory = availableMemory
    }

    /// Fraction of a nominal ceiling the GPU allocation occupies, for a gauge.
    public func gpuFraction(of ceiling: Int) -> Double? {
        guard let gpuAllocated, ceiling > 0 else { return nil }
        return Double(gpuAllocated) / Double(ceiling)
    }
}

public enum RAVEMemoryProbe {

    /// Bytes Metal currently has allocated on `device`.
    #if canImport(Metal)
    public static func gpuAllocated(device: (any MTLDevice)?) -> Int? {
        device?.currentAllocatedSize
    }
    #endif

    /// This process's physical footprint — the number jetsam judges.
    public static func processFootprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }

    /// Bytes this process may still allocate before it is terminated.
    public static func availableMemory() -> Int? {
        #if os(visionOS) || os(iOS) || os(tvOS) || os(watchOS)
        let available = os_proc_available_memory()
        return available > 0 ? available : nil
        #else
        // Not available on macOS, where the process is not under a hard cap.
        return nil
        #endif
    }

    /// Everything at once.
    #if canImport(Metal)
    public static func reading(device: (any MTLDevice)? = nil) -> RAVEMemoryReading {
        RAVEMemoryReading(
            gpuAllocated: gpuAllocated(device: device),
            processFootprint: processFootprint(),
            availableMemory: availableMemory()
        )
    }
    #else
    public static func reading() -> RAVEMemoryReading {
        RAVEMemoryReading(
            processFootprint: processFootprint(),
            availableMemory: availableMemory()
        )
    }
    #endif

    /// `ByteCountFormatter` with the settings every one of these readouts used:
    /// memory count style, KB through GB.
    public static func format(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
