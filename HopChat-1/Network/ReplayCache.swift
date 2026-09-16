//
//  ReplayCache.swift
//  HopChat-1
//
//  Contract §3: receivers keep a txID cache for 600 s and reject repeats.
//  Also hosts the per-source-IP token bucket used by the LAN listener.
//
//  Both types are used from the networking dispatch queues, so they are
//  `nonisolated` and lock-guarded rather than actor-isolated.
//

import Foundation

/// Bounded, self-pruning set of recently seen transaction IDs.
nonisolated final class ReplayCache: @unchecked Sendable {

    private let ttl: TimeInterval
    private let maxEntries: Int
    private let lock = NSLock()
    private var seen: [String: Date] = [:]

    init(ttl: TimeInterval = 600, maxEntries: Int = 20_000) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Records `txID`. Returns `false` when it was already present (a replay).
    @discardableResult
    func record(_ txID: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)
        if let at = seen[txID], now.timeIntervalSince(at) <= ttl {
            return false
        }
        seen[txID] = now
        return true
    }

    func contains(_ txID: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = seen[txID] else { return false }
        return now.timeIntervalSince(at) <= ttl
    }

    func removeAll() {
        lock.lock()
        seen.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    /// Caller holds `lock`.
    private func prune(now: Date) {
        if seen.count > maxEntries {
            // Hard cap breached (flood): drop the oldest half outright.
            let sorted = seen.sorted { $0.value < $1.value }
            for (key, _) in sorted.prefix(seen.count / 2) { seen.removeValue(forKey: key) }
            return
        }
        guard seen.count > 64 else { return }
        seen = seen.filter { now.timeIntervalSince($0.value) <= ttl }
    }
}

/// Per-key token bucket. Used to cap inbound LAN messages per source IP
/// (30 messages / minute) so one host cannot flood the listener.
nonisolated final class TokenBucket: @unchecked Sendable {

    private let capacity: Double
    /// Tokens refilled per second.
    private let refillRate: Double
    private let lock = NSLock()
    private var buckets: [String: (tokens: Double, updated: Date)] = [:]
    private let maxKeys: Int

    init(capacity: Int = 30, per interval: TimeInterval = 60, maxKeys: Int = 512) {
        self.capacity = Double(capacity)
        self.refillRate = Double(capacity) / interval
        self.maxKeys = maxKeys
    }

    /// Consumes one token for `key`. Returns `false` when the bucket is empty.
    func consume(_ key: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if buckets.count > maxKeys {
            // Evict keys that have fully refilled (i.e. idle) before growing.
            buckets = buckets.filter { _, value in
                let refilled = value.tokens + now.timeIntervalSince(value.updated) * refillRate
                return refilled < capacity
            }
        }

        var entry = buckets[key] ?? (tokens: capacity, updated: now)
        let elapsed = max(0, now.timeIntervalSince(entry.updated))
        entry.tokens = min(capacity, entry.tokens + elapsed * refillRate)
        entry.updated = now

        guard entry.tokens >= 1 else {
            buckets[key] = entry
            return false
        }
        entry.tokens -= 1
        buckets[key] = entry
        return true
    }

    func removeAll() {
        lock.lock()
        buckets.removeAll()
        lock.unlock()
    }
}

/// Exponential backoff with jitter (contract: 1 s → 60 s).
nonisolated struct Backoff {
    var base: TimeInterval = 1
    var cap: TimeInterval = 60
    private(set) var attempt: Int = 0

    mutating func next() -> TimeInterval {
        let exponent = min(attempt, 16)
        let raw = min(cap, base * pow(2, Double(exponent)))
        attempt += 1
        // Full jitter in [raw/2, raw].
        return raw / 2 + Double.random(in: 0...(raw / 2))
    }

    mutating func reset() { attempt = 0 }
}
