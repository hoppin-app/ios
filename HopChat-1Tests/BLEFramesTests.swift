//
//  BLEFramesTests.swift
//  HopChat-1Tests
//
//  The BLE link's framing layer: chunking a link message to fit a BLE write,
//  reassembling it from chunks that may arrive out of order, twice, or not at
//  all — and the link hello.
//
//  Chunks come from strangers over an unauthenticated link, so most of this
//  file is about what the reassembler *refuses*: a length it cannot honour, a
//  frame that would grow past 16 KiB, a frame that never finishes. None of it
//  may throw, trap or hold memory.
//

import Testing
import Foundation
@testable import HopChat_1

// MARK: - Support

/// A clock the test moves by hand, so timeouts don't need real time.
@MainActor
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

/// Deterministic noise: a fuzz failure must be reproducible.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func payload(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}

private func header(frameID: UInt16, total: UInt16, index: UInt16) -> Data {
    Data([UInt8(frameID >> 8), UInt8(truncatingIfNeeded: frameID),
          UInt8(total >> 8), UInt8(truncatingIfNeeded: total),
          UInt8(index >> 8), UInt8(truncatingIfNeeded: index)])
}

// MARK: - Chunking and reassembly

@MainActor
@Suite("BLE framing — chunk and reassemble")
struct BLEFramesRoundTripTests {

    /// Feeds chunks in order and returns the one assembled message.
    private func assemble(_ chunks: [Data], into sink: BLEReassembler) -> BLEFrame.Assembled? {
        var out: BLEFrame.Assembled?
        for chunk in chunks {
            if let done = sink.accept(chunk) {
                #expect(out == nil, "only the last chunk may complete a frame")
                out = done
            }
        }
        return out
    }

    @Test("a message survives every chunk size and payload size")
    func roundTrip() throws {
        for maxChunk in [20, 23, 182, 512] {
            let capacity = maxChunk - BLEFrame.headerSize
            for length in [0, 1, 181, 182, 183, 5_000, BLEFrame.maxMessageBytes - 1] {
                let body = payload(length)
                let expected = (length + 1 + capacity - 1) / capacity
                guard expected <= BLEFrame.maxChunks else {
                    #expect(BLEFrame.chunks(kind: .packet, payload: body,
                                            maxChunk: maxChunk, frameID: 1) == nil,
                            "\(length) B in \(maxChunk) B chunks needs \(expected) chunks")
                    continue
                }
                let chunks = try #require(BLEFrame.chunks(kind: .packet, payload: body,
                                                          maxChunk: maxChunk, frameID: 9))
                let sink = BLEReassembler()
                let done = try #require(assemble(chunks, into: sink),
                                        "\(length) B in \(maxChunk) B chunks did not assemble")
                #expect(done == BLEFrame.Assembled(kind: .packet, payload: body))
                #expect(sink.droppedChunks == 0)
                #expect(sink.pendingFrameCount == 0)
            }
        }
    }

    @Test("no chunk exceeds the negotiated size and the count is the exact ceiling")
    func chunkSizes() throws {
        for maxChunk in [20, 23, 182, 512] {
            let capacity = maxChunk - BLEFrame.headerSize
            for length in [0, 1, 181, 182, 183, 5_000] {
                let expected = (length + 1 + capacity - 1) / capacity
                guard expected <= BLEFrame.maxChunks else { continue }
                let chunks = try #require(BLEFrame.chunks(kind: .hello, payload: payload(length),
                                                          maxChunk: maxChunk, frameID: 0))
                #expect(chunks.count == expected,
                        "\(length) B in \(maxChunk) B chunks: \(chunks.count) != \(expected)")
                #expect(chunks.allSatisfy { $0.count <= maxChunk })
                #expect(chunks.allSatisfy { $0.count > BLEFrame.headerSize })
            }
        }
    }

    @Test("the kind byte travels inside the frame, not per chunk")
    func kindRoundTrip() throws {
        for kind in [BLEFrame.Kind.hello, .packet] {
            let chunks = try #require(BLEFrame.chunks(kind: kind, payload: payload(300),
                                                      maxChunk: 64, frameID: 3))
            let sink = BLEReassembler()
            let done = try #require(assemble(chunks, into: sink))
            #expect(done.kind == kind)
            #expect(done.payload == payload(300))
        }
    }

    @Test("chunks may arrive in any order")
    func outOfOrder() throws {
        let body = payload(900)
        let chunks = try #require(BLEFrame.chunks(kind: .packet, payload: body,
                                                  maxChunk: 100, frameID: 42))
        #expect(chunks.count > 5)
        let sink = BLEReassembler()
        let done = try #require(assemble(chunks.reversed(), into: sink))
        #expect(done.payload == body)
        #expect(sink.droppedChunks == 0)
    }

    @Test("a repeated chunk is ignored, not counted twice")
    func duplicates() throws {
        let body = payload(400)
        let chunks = try #require(BLEFrame.chunks(kind: .packet, payload: body,
                                                  maxChunk: 60, frameID: 7))
        let sink = BLEReassembler()
        for chunk in chunks.dropLast() {
            #expect(sink.accept(chunk) == nil)
            #expect(sink.accept(chunk) == nil, "the duplicate must change nothing")
        }
        let done = try #require(sink.accept(chunks[chunks.count - 1]))
        #expect(done.payload == body)
        #expect(sink.droppedChunks == chunks.count - 1, "every duplicate should be dropped")
        #expect(sink.pendingFrameCount == 0)
    }

    @Test("two interleaved frames both assemble")
    func interleaved() throws {
        let first = payload(300), second = payload(450)
        let a = try #require(BLEFrame.chunks(kind: .packet, payload: first, maxChunk: 40, frameID: 1))
        let b = try #require(BLEFrame.chunks(kind: .hello, payload: second, maxChunk: 40, frameID: 2))
        let sink = BLEReassembler()

        var results: [BLEFrame.Assembled] = []
        for index in 0..<max(a.count, b.count) {
            if index < a.count, let done = sink.accept(a[index]) { results.append(done) }
            if index < b.count, let done = sink.accept(b[index]) { results.append(done) }
        }
        #expect(results.count == 2)
        #expect(results.contains(BLEFrame.Assembled(kind: .packet, payload: first)))
        #expect(results.contains(BLEFrame.Assembled(kind: .hello, payload: second)))
        #expect(sink.droppedChunks == 0)
    }
}

// MARK: - Refusals

@MainActor
@Suite("BLE framing — hostile and impossible input")
struct BLEFramesRejectionTests {

    @Test("garbage and truncated chunks are dropped")
    func garbage() {
        let sink = BLEReassembler()
        #expect(sink.accept(Data()) == nil)
        #expect(sink.accept(Data(repeating: 0, count: BLEFrame.headerSize)) == nil,
                "a header with no bytes carries nothing")
        #expect(sink.accept(header(frameID: 1, total: 1, index: 0).prefix(3)) == nil)
        #expect(sink.accept(header(frameID: 1, total: 0, index: 0) + Data([1])) == nil,
                "total 0 is meaningless")
        #expect(sink.accept(header(frameID: 1, total: UInt16(BLEFrame.maxChunks + 1), index: 0)
                            + Data([1])) == nil)
        #expect(sink.accept(header(frameID: 1, total: 2, index: 2) + Data([1])) == nil,
                "index must be inside total")
        #expect(sink.accept(header(frameID: 1, total: 2, index: 9) + Data([1])) == nil)
        // An unknown kind byte cannot be dispatched, so the frame is refused.
        #expect(sink.accept(header(frameID: 1, total: 1, index: 0) + Data([0xEE])) == nil)
        #expect(sink.droppedChunks == 8)
        #expect(sink.pendingFrameCount == 0)
    }

    @Test("a total that changes mid-frame is a different frame wearing the same id")
    func changedTotal() throws {
        let sink = BLEReassembler()
        #expect(sink.accept(header(frameID: 5, total: 3, index: 0) + Data([2, 1, 2])) == nil)
        #expect(sink.accept(header(frameID: 5, total: 2, index: 1) + Data([3, 4])) == nil)
        #expect(sink.droppedChunks == 1)
        // The original frame is untouched and still completes.
        #expect(sink.accept(header(frameID: 5, total: 3, index: 1) + Data([3, 4])) == nil)
        let done = try #require(sink.accept(header(frameID: 5, total: 3, index: 2) + Data([5])))
        #expect(done == BLEFrame.Assembled(kind: .packet, payload: Data([1, 2, 3, 4, 5])))
    }

    @Test("a frame that would grow past the message limit is abandoned")
    func oversizedAssembly() {
        let sink = BLEReassembler()
        let big = Data(repeating: 0xAB, count: BLEFrame.maxMessageBytes)
        #expect(sink.accept(header(frameID: 1, total: 2, index: 0) + big) == nil)
        #expect(sink.pendingFrameCount == 1)
        #expect(sink.accept(header(frameID: 1, total: 2, index: 1) + big) == nil)
        #expect(sink.droppedChunks == 1)
        #expect(sink.pendingFrameCount == 0, "the frame can never assemble legally")

        // A single over-long chunk never opens a frame at all.
        let sink2 = BLEReassembler()
        #expect(sink2.accept(header(frameID: 1, total: 1, index: 0)
                             + Data(repeating: 1, count: BLEFrame.maxMessageBytes + 1)) == nil)
        #expect(sink2.pendingFrameCount == 0)
    }

    @Test("chunks() refuses sizes it cannot honour")
    func impossibleChunking() {
        #expect(BLEFrame.chunks(kind: .packet, payload: Data([1]),
                                maxChunk: BLEFrame.headerSize, frameID: 0) == nil)
        #expect(BLEFrame.chunks(kind: .packet, payload: Data([1]), maxChunk: 0, frameID: 0) == nil)
        #expect(BLEFrame.chunks(kind: .packet, payload: Data([1]), maxChunk: -5, frameID: 0) == nil)
        #expect(BLEFrame.chunks(kind: .packet, payload: Data([1]),
                                maxChunk: BLEFrame.headerSize + 1, frameID: 0) != nil,
                "one byte per chunk is legal, just wasteful")

        // Too big for the message limit, and too big for 512 chunks.
        #expect(BLEFrame.chunks(kind: .packet, payload: payload(BLEFrame.maxMessageBytes),
                                maxChunk: 512, frameID: 0) == nil)
        #expect(BLEFrame.chunks(kind: .packet, payload: payload(BLEFrame.maxMessageBytes - 1),
                                maxChunk: 512, frameID: 0) != nil)
        #expect(BLEFrame.chunks(kind: .packet, payload: payload(8_000),
                                maxChunk: 20, frameID: 0) == nil,
                "14 B per chunk cannot carry 8 KiB in 512 chunks")
    }
}

// MARK: - Lifetime

@MainActor
@Suite("BLE framing — timeout and pending frames")
struct BLEFramesLifetimeTests {

    @Test("an incomplete frame is dropped after the timeout")
    func timeout() throws {
        let clock = FakeClock()
        let sink = BLEReassembler(now: { clock.now }, timeout: 10)
        let chunks = try #require(BLEFrame.chunks(kind: .packet, payload: payload(200),
                                                  maxChunk: 40, frameID: 1))
        for chunk in chunks.dropLast() { #expect(sink.accept(chunk) == nil) }
        #expect(sink.pendingFrameCount == 1)

        clock.advance(5)
        sink.sweep()
        #expect(sink.pendingFrameCount == 1, "still inside the window")

        clock.advance(6)
        sink.sweep()
        #expect(sink.pendingFrameCount == 0)

        // The late chunk starts nothing and completes nothing.
        #expect(sink.accept(chunks[chunks.count - 1]) == nil)
        #expect(sink.pendingFrameCount == 1, "it is now the first chunk of a new frame")
    }

    @Test("a fifth frame evicts the oldest")
    func pendingLimit() throws {
        let clock = FakeClock()
        let sink = BLEReassembler(now: { clock.now }, timeout: 10, maxPendingFrames: 4)
        for frameID in UInt16(1)...UInt16(4) {
            #expect(sink.accept(header(frameID: frameID, total: 2, index: 0) + Data([2, 0])) == nil)
            clock.advance(1)
        }
        #expect(sink.pendingFrameCount == 4)

        #expect(sink.accept(header(frameID: 5, total: 2, index: 0) + Data([2, 0])) == nil)
        #expect(sink.pendingFrameCount == 4, "the cap holds")

        // Frame 2 survived the eviction and still completes...
        let done = try #require(sink.accept(header(frameID: 2, total: 2, index: 1) + Data([9])))
        #expect(done == BLEFrame.Assembled(kind: .packet, payload: Data([0, 9])))
        // ...while frame 1, the oldest, is gone: its second chunk now starts a
        // fresh frame instead of completing one.
        #expect(sink.accept(header(frameID: 1, total: 2, index: 1) + Data([9])) == nil)
    }

    @Test("a single-chunk message never occupies a pending slot")
    func singleChunkDoesNotEvict() throws {
        let sink = BLEReassembler(maxPendingFrames: 4)
        #expect(sink.accept(header(frameID: 1, total: 2, index: 0) + Data([2, 0])) == nil)
        for frameID in UInt16(10)...UInt16(20) {
            #expect(sink.accept(header(frameID: frameID, total: 1, index: 0) + Data([1])) != nil)
        }
        #expect(sink.pendingFrameCount == 1)
        let done = try #require(sink.accept(header(frameID: 1, total: 2, index: 1) + Data([7])))
        #expect(done == BLEFrame.Assembled(kind: .packet, payload: Data([0, 7])))
    }
}

// MARK: - Link hello

@Suite("BLE framing — link hello")
struct BLEHelloTests {

    @Test("a hello survives the round trip")
    func roundTrip() throws {
        for maxFrameBytes in [1, 20, 182, 512, 65_535] {
            let hello = BLEHello(nodeID: BLEHello.randomNodeID(), maxFrameBytes: maxFrameBytes)
            let encoded = hello.encoded()
            #expect(encoded.count == BLEHello.encodedSize)
            #expect(BLEHello.decode(encoded) == hello)
        }
    }

    @Test("malformed hellos are refused")
    func rejects() throws {
        let good = BLEHello(nodeID: BLEHello.randomNodeID(), maxFrameBytes: 182).encoded()
        #expect(BLEHello.decode(Data()) == nil)
        #expect(BLEHello.decode(good.prefix(good.count - 1)) == nil)
        #expect(BLEHello.decode(good + Data([0])) == nil, "trailing bytes must fail")

        var zeroVersion = good
        zeroVersion[zeroVersion.startIndex] = 0
        #expect(BLEHello.decode(zeroVersion) == nil, "version 0 is not a protocol")

        var zeroFrame = good
        zeroFrame[zeroFrame.startIndex + 17] = 0
        zeroFrame[zeroFrame.startIndex + 18] = 0
        #expect(BLEHello.decode(zeroFrame) == nil, "a peer that accepts nothing is unusable")
    }

    @Test("a newer version and unknown flag bits stay connectable")
    func forwardCompatible() throws {
        var future = BLEHello(nodeID: BLEHello.randomNodeID(), maxFrameBytes: 244).encoded()
        future[future.startIndex] = 9
        future[future.startIndex + 19] = 0xFF
        let decoded = try #require(BLEHello.decode(future))
        #expect(decoded.version == 9)
        #expect(decoded.maxFrameBytes == 244)
        #expect(decoded.nodeID.count == BLEHello.nodeIDSize)
    }

    @Test("node ids are 16 random bytes and carry no identity")
    func nodeIDs() {
        let ids = (0..<32).map { _ in BLEHello.randomNodeID() }
        #expect(ids.allSatisfy { $0.count == 16 })
        #expect(Set(ids).count == ids.count, "a repeated node id would link two connections")
    }
}

// MARK: - Fuzz

@MainActor
@Suite("BLE framing — fuzz")
struct BLEFramesFuzzTests {

    @Test("random bytes never crash the reassembler and never assemble a lie")
    func fuzz() {
        var rng = SeededRNG(seed: 0xA5A5_1234_DEAD_BEEF)
        let sink = BLEReassembler()
        for _ in 0..<500 {
            let length = Int.random(in: 0...64, using: &rng)
            var blob = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            // Half the blobs get a plausible header, so the parser is actually
            // reached instead of bouncing off the length check.
            if length >= BLEFrame.headerSize + 1, Bool.random(using: &rng) {
                blob.replaceSubrange(blob.startIndex..<(blob.startIndex + BLEFrame.headerSize),
                                     with: header(frameID: UInt16.random(in: 0...3, using: &rng),
                                                  total: UInt16.random(in: 0...4, using: &rng),
                                                  index: UInt16.random(in: 0...4, using: &rng)))
            }
            guard let done = sink.accept(blob) else { continue }
            #expect(done.payload.count + 1 <= BLEFrame.maxMessageBytes)
            // A one-chunk frame must reproduce its own bytes exactly.
            let total = Int(blob[blob.startIndex + 2]) << 8 | Int(blob[blob.startIndex + 3])
            if total == 1 {
                let body = Data(blob[(blob.startIndex + BLEFrame.headerSize)...])
                #expect(done.kind.rawValue == body.first)
                #expect(done.payload == body.dropFirst())
            }
        }
        #expect(sink.pendingFrameCount <= 4)
    }
}
