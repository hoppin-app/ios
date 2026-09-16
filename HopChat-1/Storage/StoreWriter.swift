//
//  StoreWriter.swift
//  HopChat-1
//
//  The single serial writer for every file the store owns.
//
//  Why this exists: the previous store spawned a detached task per save, each
//  writing a full snapshot. Tasks could complete out of order, so an older
//  snapshot could land last and silently destroy newer messages.
//
//  Here every operation carries a per-file monotonically increasing version.
//  Operations are coalesced per path (newest wins), bursts are debounced, and
//  anything older than what has already hit disk is dropped.
//

import Foundation
import os

// Actors carry their own isolation, so this stays off the main actor even with
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
actor StoreWriter {

    enum Operation: Sendable {
        case write(Data)
        case delete
    }

    private struct Pending {
        var operation: Operation
        var version: UInt64
    }

    private var pending: [URL: Pending] = [:]
    private var lastWritten: [URL: UInt64] = [:]
    private var scheduled: Task<Void, Never>?
    private let debounce: Duration
    private let fm = FileManager.default

    init(debounce: Duration = .milliseconds(150)) {
        self.debounce = debounce
    }

    // MARK: - Enqueue

    func write(_ data: Data, to url: URL, version: UInt64) {
        enqueue(.write(data), to: url, version: version)
    }

    func delete(_ url: URL, version: UInt64) {
        enqueue(.delete, to: url, version: version)
    }

    private func enqueue(_ operation: Operation, to url: URL, version: UInt64) {
        // Stale relative to what is already on disk.
        if let written = lastWritten[url], version <= written { return }
        // Stale relative to a newer snapshot already queued for this path.
        if let queued = pending[url], version <= queued.version { return }
        pending[url] = Pending(operation: operation, version: version)
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard scheduled == nil, !pending.isEmpty else { return }
        let delay = debounce
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        scheduled = nil
        drain()
    }

    // MARK: - Flush

    /// Forces every queued operation to complete before returning.
    func flush() {
        scheduled?.cancel()
        scheduled = nil
        drain()
    }

    /// Drops everything queued and removes the whole directory tree.
    func wipe(directory: URL) {
        scheduled?.cancel()
        scheduled = nil
        pending.removeAll()
        lastWritten.removeAll()
        try? fm.removeItem(at: directory)
    }

    // MARK: - Drain

    // Synchronous on purpose: it runs to completion inside the actor, so no other
    // operation can interleave and reorder writes.
    private func drain() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        for (url, item) in batch {
            if let written = lastWritten[url], item.version <= written { continue }
            do {
                switch item.operation {
                case .write(let data):
                    try ensureParent(of: url)
                    try data.write(to: url, options: StorageProtection.writingOptions)
                case .delete:
                    if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                    }
                }
                lastWritten[url] = item.version
            } catch {
                Log.store.error("store write failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func ensureParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard !fm.fileExists(atPath: parent.path) else { return }
        try fm.createDirectory(at: parent,
                               withIntermediateDirectories: true,
                               attributes: StorageProtection.directoryAttributes)
    }
}
