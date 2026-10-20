//
//  ServerClock.swift
//  HopChat-1
//
//  The relay's idea of "now", as this device best knows it.
//
//  Every timestamp hoppin signs or checks is compared with another machine's
//  clock: the relay refuses a request more than 300 s from its own time, and
//  certificates and envelopes are judged against "now" on both ends. The
//  device's clock can be badly wrong — App Review's iPad was 16 days ahead,
//  and every sign-in failed — so the app keeps the offset the relay's own
//  signed replies imply and stamps and judges everything in relay time.
//
//  Only a reply that passed `ServerClient`'s checks teaches it: signed with the
//  pinned server key, and echoing a txID this device just generated, so it is
//  both genuine and current. The offset lives in memory; after a relaunch the
//  first request may be refused as stale, which teaches it again (the client
//  retries once).
//

import Foundation
import os

nonisolated enum ServerClock {

    private struct State {
        var offset: TimeInterval = 0
        var device: @Sendable () -> Date = { Date() }
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Relay time: the device clock corrected by what the relay last told us.
    static func now() -> Date {
        state.withLock { $0.device().addingTimeInterval($0.offset) }
    }

    /// Unix seconds in relay time, the unit every wire timestamp uses.
    static func timestamp() -> Int64 {
        Int64(now().timeIntervalSince1970)
    }

    /// Relay time minus device time, in seconds.
    static var offset: TimeInterval {
        state.withLock { $0.offset }
    }

    /// Learns from a verified server reply stamped `serverTimestamp`.
    static func learn(serverTimestamp: Int64) {
        state.withLock { s in
            let device = s.device().timeIntervalSince1970
            let offset = TimeInterval(serverTimestamp) - device
            // Whole-second stamps and network time make a correct clock look
            // a second or two off; ignore that, so "now" doesn't jitter.
            s.offset = abs(offset) < 5 ? 0 : offset
        }
    }

    // MARK: - Tests

    /// Replaces the device clock (pass `nil` to restore it) and forgets the offset.
    static func setDeviceClockForTesting(_ clock: (@Sendable () -> Date)?) {
        state.withLock { s in
            s.device = clock ?? { Date() }
            s.offset = 0
        }
    }
}
