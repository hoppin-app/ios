//
//  TranslationService.swift
//  HopChat-1
//
//  Bridges the async world (the receive path) to `TranslationBridgeView`, which
//  owns the `TranslationSession` that SwiftUI insists on vending from a view.
//
//  v1 bug fixed here: a request handed to the bridge could hang forever — if
//  the bridge view disappeared, if `translationTask` never produced a session
//  (unsupported language, model not downloaded), or if two completions raced —
//  and because v1 translated *before* persisting, one stuck continuation
//  stalled the whole receive path.
//
//  The rules now:
//   • Every continuation is stored in `continuations` and removed *before* it
//     is resumed, so it resumes exactly once, whatever path gets there first.
//   • Every request carries a 10 s timeout task.
//   • The bridge disappearing flushes the whole queue with `nil`.
//   • `KademliaService` persists first and translates afterwards, so nothing
//     here can ever block receiving.
//

import Foundation
import Combine
import os

@MainActor
final class TranslationService: ObservableObject {

    static let shared = TranslationService()

    private init() {}

    /// How long a single request may wait for the bridge before giving up.
    static let requestTimeout: TimeInterval = 10

    struct PendingRequest: Identifiable, Equatable {
        let id: UUID
        let text: String
        let targetLang: String

        nonisolated static func == (lhs: PendingRequest, rhs: PendingRequest) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// The request the bridge view should work on right now.
    @Published private(set) var pendingRequest: PendingRequest?

    private var queue: [PendingRequest] = []
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var bridgeIsActive = false

    // MARK: - Public API

    /// Translates `body` using the user's auto-translate settings.
    /// Returns `nil` when disabled, unavailable, timed out, or failed —
    /// callers treat `nil` as "show the original".
    func autoTranslate(body: String) async -> String? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppConfig.Keys.autoTranslate) else { return nil }
        let lang = defaults.string(forKey: AppConfig.Keys.translateLang) ?? "en"
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await translate(text: trimmed, to: lang)
    }

    func translate(text: String, to targetLangCode: String) async -> String? {
        let request = PendingRequest(id: UUID(), text: text, targetLang: targetLangCode)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            enqueue(request, continuation: continuation)
        }
    }

    // MARK: - Bridge callbacks

    /// Called by `TranslationBridgeView` when translation finished (or failed).
    func complete(request: PendingRequest, result: String?) {
        finish(request.id, with: result)
    }

    func bridgeDidAppear() {
        bridgeIsActive = true
        // The bridge may have come back after a flush; make sure it is pointed
        // at whatever is waiting.
        if pendingRequest == nil { advance() }
    }

    /// The bridge went away: nothing can complete these any more, so resolve
    /// them all rather than leaving continuations dangling.
    func bridgeDidDisappear() {
        bridgeIsActive = false
        flushAll()
    }

    /// Resumes every outstanding request with `nil` and clears the queue.
    func flushAll() {
        let ids = Array(continuations.keys)
        queue.removeAll()
        pendingRequest = nil
        for id in ids { finish(id, with: nil) }
    }

    // MARK: - Queue plumbing

    private func enqueue(_ request: PendingRequest,
                         continuation: CheckedContinuation<String?, Never>) {
        continuations[request.id] = continuation
        timeouts[request.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TranslationService.requestTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            Log.ui.debug("Translation request timed out after \(TranslationService.requestTimeout, privacy: .public)s")
            self?.finish(request.id, with: nil)
        }

        if pendingRequest == nil {
            pendingRequest = request
        } else {
            queue.append(request)
        }
    }

    /// Resumes a request exactly once. Removing the continuation *before*
    /// resuming is what makes a double completion (bridge + timeout, or two
    /// bridge callbacks) harmless.
    private func finish(_ id: UUID, with result: String?) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: result)

        if pendingRequest?.id == id {
            pendingRequest = nil
            advance()
        } else {
            queue.removeAll { $0.id == id }
        }
    }

    private func advance() {
        guard pendingRequest == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        // Go through `nil` on a later turn so the bridge's `onChange` always
        // observes a transition, even for back-to-back same-language requests.
        Task { @MainActor [weak self] in
            guard let self, self.pendingRequest == nil else { return }
            guard self.continuations[next.id] != nil else {
                self.advance()
                return
            }
            self.pendingRequest = next
        }
    }
}
