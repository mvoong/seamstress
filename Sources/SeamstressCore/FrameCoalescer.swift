import CoreGraphics
import Foundation

/// Pure latest-frame coalescing state machine for a single target process (PID).
///
/// While an AX IPC write is in flight for a PID, incoming live-resize frames overwrite
/// the pending slot instead of queueing up behind the busy app. As soon as the in-flight
/// write completes, `completeCurrent()` pops the most recent pending targets in a single
/// batch so fast apps stay at 60Hz+ and slow Electron apps never build a lag backlog.
public struct PerPIDFrameCoalescer: Sendable {
    private var inFlight: Bool = false
    private var pending: [WindowID: CGRect] = [:]

    public init() {}

    public var isBusy: Bool { inFlight }
    public var hasPending: Bool { !pending.isEmpty }

    /// Enqueue a target frame for `windowID`.
    /// Returns a batch to dispatch immediately if the PID is idle, or `nil` if a write is
    /// already in flight (the frame is coalesced and will run as soon as the current write finishes).
    public mutating func enqueue(windowID: WindowID, frame: CGRect) -> [(WindowID, CGRect)]? {
        pending[windowID] = frame
        guard !inFlight else { return nil }
        return popBatch()
    }

    /// Enqueue multiple frames for the same PID in one shot.
    public mutating func enqueueBatch(_ updates: [(WindowID, CGRect)]) -> [(WindowID, CGRect)]? {
        for (wid, frame) in updates {
            pending[wid] = frame
        }
        guard !inFlight, !pending.isEmpty else { return nil }
        return popBatch()
    }

    /// Mark the in-flight batch complete. Returns the next coalesced batch if newer frames
    /// arrived while the previous write was running, or `nil` if now idle.
    public mutating func completeCurrent() -> [(WindowID, CGRect)]? {
        guard !pending.isEmpty else {
            inFlight = false
            return nil
        }
        return popBatch()
    }

    public mutating func reset() {
        inFlight = false
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func popBatch() -> [(WindowID, CGRect)] {
        inFlight = true
        let batch = pending.sorted(by: { $0.key < $1.key })
        pending.removeAll(keepingCapacity: true)
        return batch
    }
}
