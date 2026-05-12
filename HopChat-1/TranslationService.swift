//
//  TranslationService.swift
//  HopChat-1
//

import Foundation
import Combine
import Translation

@MainActor
final class TranslationService: ObservableObject {
    static let shared = TranslationService()
    private init() {}

    struct PendingRequest: Identifiable {
        let id    = UUID()
        let text:       String
        let targetLang: String
        let continuation: CheckedContinuation<String?, Never>
    }

    @Published private(set) var pendingRequest: PendingRequest?
    private var pendingQueue: [PendingRequest] = []

    // Called by TranslationBridgeView once translation completes.
    func complete(request: PendingRequest, result: String?) {
        request.continuation.resume(returning: result)
        // Advance the queue: go through nil so onChange always sees a change
        // even when consecutive requests share the same target language.
        pendingRequest = nil
        if !pendingQueue.isEmpty {
            Task { @MainActor in
                self.pendingRequest = self.pendingQueue.removeFirst()
            }
        }
    }

    // MARK: - Public API

    func translate(text: String, to targetLangCode: String) async -> String? {
        await withCheckedContinuation { continuation in
            let req = PendingRequest(text: text, targetLang: targetLangCode, continuation: continuation)
            if pendingRequest == nil {
                pendingRequest = req
            } else {
                pendingQueue.append(req)
            }
        }
    }

    /// Translates `body` using the user's stored auto-translate settings.
    /// Returns nil if auto-translate is disabled, unavailable, or fails.
    func autoTranslate(body: String) async -> String? {
        let enabled  = UserDefaults.standard.bool(forKey: "hopchat.autoTranslate")
        let langCode = UserDefaults.standard.string(forKey: "hopchat.translateLang") ?? "en"
        guard enabled else { return nil }
        return await translate(text: body, to: langCode)
    }
}
