//
//  BLEFrames.swift
//  HopChat-1
//
//  The BLE link's framing layer (contract §9.7). A link message is
//  `[kind 1 B][payload]`; BLE can only carry a couple of hundred bytes per
//  write, so the message is split into chunks:
//
//      [frameID 2 B BE][total 2 B BE][index 2 B BE][bytes]
//
//  There is no CoreBluetooth here on purpose — the same reason `MeshRouter`
//  has none. Framing is pure logic, so loss, reordering and hostile input can
//  all be exercised in the simulator.
//
//  Everything that arrives here comes from a stranger who has not authenticated
//  anything (authentication stays end-to-end, inside the sealed envelope), and
//  a chunk is the *first* thing that costs us memory. So reassembly never
//  throws, never traps and never allocates on trust: `total` and `index` are
//  range-checked before a buffer exists, the running size is capped at
//  `maxMessageBytes`, and at most four frames may be in flight per link.
//

import Foundation
import CryptoKit

nonisolated enum BLEFrame {

    enum Kind: UInt8, Sendable {
        /// Link hello (`BLEHello`), the first message on every link.
        case hello = 1
        /// A `MeshPacket.encoded()`.
        case packet = 2
    }

    /// A finished link message: the kind byte, and everything after it.
    struct Assembled: Equatable, Sendable {
        let kind: Kind
        let payload: Data
    }

    /// Chunk header size (frameID 2 B, total 2 B, index 2 B).
    static let headerSize = 6
    static let maxChunks = 512
    /// Largest assembled link message (MeshPacket limits + the kind byte).
    static let maxMessageBytes = MeshPacket.headerSize + MeshPacket.maxBodyBytes + 1

    /// Splits `[kind][payload]` into chunks of at most `maxChunk` bytes each
    /// (header included). Returns nil when maxChunk is too small (<= headerSize)
    /// or the message would need more than `maxChunks` chunks / exceed
    /// maxMessageBytes.
    static func chunks(kind: Kind, payload: Data, maxChunk: Int, frameID: UInt16) -> [Data]? {
        guard maxChunk > headerSize else { return nil }
        // The kind byte rides inside the split, so a one-byte link message is
        // still one chunk and the receiver learns the kind only once.
        let messageSize = payload.count + 1
        guard messageSize <= maxMessageBytes else { return nil }

        let capacity = maxChunk - headerSize
        let total = (messageSize + capacity - 1) / capacity
        guard total >= 1, total <= maxChunks else { return nil }

        var message = Data(capacity: messageSize)
        message.append(kind.rawValue)
        message.append(payload)

        var out = [Data]()
        out.reserveCapacity(total)
        for index in 0..<total {
            let start = message.startIndex + index * capacity
            let end = min(start + capacity, message.endIndex)
            var chunk = Data(capacity: headerSize + (end - start))
            chunk.append(bigEndian: frameID)
            chunk.append(bigEndian: UInt16(total))
            chunk.append(bigEndian: UInt16(index))
            chunk.append(message[start..<end])
            out.append(chunk)
        }
        return out
    }
}

// MARK: - Reassembly

/// Reassembles chunks arriving from ONE link. Not thread-safe by design:
/// the transport drives it on the main actor.
@MainActor
final class BLEReassembler {

    private struct Pending {
        let total: Int
        var parts: [Int: Data]
        var bytes: Int
        let startedAt: Date
    }

    private let now: () -> Date
    private let timeout: TimeInterval
    private let maxPendingFrames: Int

    private var pending: [UInt16: Pending] = [:]
    /// Insertion order, so "evict the oldest" is deterministic even when the
    /// injected clock does not move between two frames.
    private var order: [UInt16] = []

    /// Chunks refused as malformed, out of range, duplicate or over-long.
    /// Frames lost to `sweep()` or to the pending-frame cap are not counted
    /// here: those are policy, not bad input.
    private(set) var droppedChunks = 0

    var pendingFrameCount: Int { pending.count }

    init(now: @escaping () -> Date = { Date() },
         timeout: TimeInterval = 10,
         maxPendingFrames: Int = 4) {
        self.now = now
        self.timeout = timeout
        self.maxPendingFrames = max(1, maxPendingFrames)
    }

    /// Returns the finished message when this chunk completed one, else nil.
    /// Invalid chunks are dropped (and counted).
    func accept(_ chunk: Data) -> BLEFrame.Assembled? {
        // A chunk with no bytes after the header carries nothing and can only
        // be padding or noise.
        guard chunk.count >= BLEFrame.headerSize + 1 else { return drop() }
        let start = chunk.startIndex
        func word(_ offset: Int) -> Int {
            Int(chunk[start + offset]) << 8 | Int(chunk[start + offset + 1])
        }
        let frameID = UInt16(word(0))
        let total = word(2)
        let index = word(4)
        guard total >= 1, total <= BLEFrame.maxChunks, index < total else { return drop() }

        let bytes = Data(chunk[(start + BLEFrame.headerSize)...])

        if var frame = pending[frameID] {
            // A changed `total` means these are two different frames wearing
            // the same id; trust the one already in flight and drop the rest.
            guard frame.total == total, frame.parts[index] == nil else { return drop() }
            guard frame.bytes + bytes.count <= BLEFrame.maxMessageBytes else {
                // The frame can never assemble legally, so stop paying for it.
                remove(frameID)
                return drop()
            }
            frame.parts[index] = bytes
            frame.bytes += bytes.count
            pending[frameID] = frame
            return complete(frameID, frame)
        }

        guard bytes.count <= BLEFrame.maxMessageBytes else { return drop() }
        let frame = Pending(total: total, parts: [index: bytes],
                            bytes: bytes.count, startedAt: now())
        // A whole message in one chunk never occupies a slot, so a burst of
        // small frames cannot evict a large one that is still assembling.
        guard total > 1 else { return complete(frameID, frame) }
        if pending.count >= maxPendingFrames, let oldest = order.first {
            remove(oldest)
        }
        pending[frameID] = frame
        order.append(frameID)
        return nil
    }

    /// Drops frames older than `timeout`. Call periodically.
    func sweep() {
        let cutoff = now().addingTimeInterval(-timeout)
        for frameID in order where pending[frameID].map({ $0.startedAt <= cutoff }) == true {
            remove(frameID)
        }
    }

    // MARK: - Private

    private func complete(_ frameID: UInt16, _ frame: Pending) -> BLEFrame.Assembled? {
        guard frame.parts.count == frame.total else { return nil }
        remove(frameID)

        var message = Data(capacity: frame.bytes)
        for index in 0..<frame.total {
            guard let part = frame.parts[index] else { return drop() }
            message.append(part)
        }
        guard let first = message.first, let kind = BLEFrame.Kind(rawValue: first),
              message.count <= BLEFrame.maxMessageBytes else { return drop() }
        return BLEFrame.Assembled(kind: kind, payload: Data(message.dropFirst()))
    }

    private func remove(_ frameID: UInt16) {
        pending[frameID] = nil
        order.removeAll { $0 == frameID }
    }

    /// One place to count a refusal, so every rejection path stays a one-liner.
    private func drop() -> BLEFrame.Assembled? {
        droppedChunks += 1
        return nil
    }
}

// MARK: - Link hello

/// First message on every link (contract 9.7):
/// `[version 1 B][nodeID 16 B][maxFrameBytes 2 B BE][flags 1 B]`.
///
/// Nothing here identifies a person: `nodeID` is random, rotates every 15
/// minutes and names a *connection*. There is no certificate and no signature
/// on the link — authentication stays end to end, inside the sealed envelope.
nonisolated struct BLEHello: Equatable, Sendable {

    static let currentVersion: UInt8 = 1
    static let nodeIDSize = 16
    static let encodedSize = 20

    let version: UInt8
    /// Exactly 16 bytes, rotating, no identity.
    let nodeID: Data
    /// What this side can accept, 1...65535.
    let maxFrameBytes: Int

    init(version: UInt8 = currentVersion, nodeID: Data, maxFrameBytes: Int) {
        self.version = version
        self.nodeID = nodeID
        self.maxFrameBytes = maxFrameBytes
    }

    /// Flags are written as 0; this build defines none.
    /// The initializer cannot fail (the transport builds these inline), so a
    /// malformed value is normalised here rather than producing short bytes
    /// that would desynchronise the link.
    func encoded() -> Data {
        var out = Data(capacity: Self.encodedSize)
        out.append(version)
        out.append(nodeID.prefix(Self.nodeIDSize))
        if nodeID.count < Self.nodeIDSize {
            out.append(Data(repeating: 0, count: Self.nodeIDSize - nodeID.count))
        }
        out.append(bigEndian: UInt16(min(max(maxFrameBytes, 1), 0xFFFF)))
        out.append(0)               // flags
        return out
    }

    static func decode(_ data: Data) -> BLEHello? {
        guard data.count == encodedSize else { return nil }
        let start = data.startIndex
        let version = data[start]
        guard version > 0 else { return nil }
        let nodeID = Data(data[(start + 1)..<(start + 1 + nodeIDSize)])
        let maxFrameBytes = Int(data[start + 17]) << 8 | Int(data[start + 18])
        guard maxFrameBytes > 0 else { return nil }
        // Unknown flag bits are ignored rather than rejected: a later version
        // may set one, and both sides must stay connectable.
        return BLEHello(version: version, nodeID: nodeID, maxFrameBytes: maxFrameBytes)
    }

    static func randomNodeID() -> Data {
        var bytes = [UInt8](repeating: 0, count: nodeIDSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Private

private extension Data {
    mutating func append(bigEndian value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
