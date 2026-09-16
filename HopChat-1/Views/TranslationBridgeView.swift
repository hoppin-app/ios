//
//  TranslationBridgeView.swift
//  HopChat-1
//
//  Invisible 0×0 view that owns the `TranslationSession` lifecycle. Embed once
//  near the root of the hierarchy.
//
//  Every exit path tells `TranslationService`, so no request is left waiting:
//  success, failure, and the view disappearing all resolve the continuation.
//  The service also enforces a 10 s timeout, which covers the case where
//  `translationTask` never hands us a session at all (unsupported language or
//  a model the user hasn't downloaded).
//

import SwiftUI
import Translation
import os

struct TranslationBridgeView: View {

    @ObservedObject private var service = TranslationService.shared

    @State private var config: TranslationSession.Configuration?
    @State private var readySession: TranslationSession?
    @State private var readyConfig: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                service.bridgeDidAppear()
                processNext()
            }
            .onDisappear {
                readySession = nil
                readyConfig = nil
                config = nil
                service.bridgeDidDisappear()
            }
            .onChange(of: service.pendingRequest?.id) { _, _ in
                processNext()
            }
            .translationTask(config) { session in
                readySession = session
                readyConfig = config
                await processWithSession(session)
            }
    }

    // MARK: - Private

    private func processNext() {
        guard let request = service.pendingRequest else { return }
        let needed = TranslationSession.Configuration(
            source: nil,
            target: Locale.Language(identifier: request.targetLang)
        )
        if let session = readySession, readyConfig == needed {
            Task { await processWithSession(session) }
        } else {
            // Triggers `.translationTask` to vend a fresh session.
            config = needed
        }
    }

    private func processWithSession(_ session: TranslationSession) async {
        guard let request = service.pendingRequest else { return }
        do {
            let response = try await session.translate(request.text)
            service.complete(request: request, result: response.targetText)
        } catch {
            Log.ui.error("Translation failed: \(String(describing: error), privacy: .public)")
            // Resolve rather than retry: the caller falls back to the original.
            service.complete(request: request, result: nil)
        }
    }
}
