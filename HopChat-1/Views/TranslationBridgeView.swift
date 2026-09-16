//
//  TranslationBridgeView.swift
//  HopChat-1
//
//  Invisible 0×0 view that owns the `TranslationSession` lifecycle. Embed once
//  near the root of the hierarchy. One request per run of `translationTask`;
//  the next request re-runs it (new language pair → new configuration, same
//  pair → `invalidate()`).
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

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                service.bridgeDidAppear()
                processNext()
            }
            .onDisappear {
                config = nil
                service.bridgeDidDisappear()
            }
            .onChange(of: service.pendingRequest?.id) { _, _ in
                processNext()
            }
            // The session is only valid inside this closure, so it is never
            // stored; every request runs the task again.
            .translationTask(config) { session in
                await process(with: session)
            }
    }

    // MARK: - Private

    private func processNext() {
        guard let request = service.pendingRequest else { return }
        let needed = TranslationSession.Configuration(
            source: Locale.Language(identifier: request.sourceLang),
            target: Locale.Language(identifier: request.targetLang)
        )
        if config?.source == needed.source, config?.target == needed.target {
            // Same language pair: re-run the task with the existing configuration.
            config?.invalidate()
        } else {
            config = needed
        }
    }

    private func process(with session: TranslationSession) async {
        guard let request = service.pendingRequest,
              config?.source == Locale.Language(identifier: request.sourceLang),
              config?.target == Locale.Language(identifier: request.targetLang) else { return }
        do {
            // No-op when the models are installed; otherwise the system asks
            // to download them (only interactive requests get this far).
            try await session.prepareTranslation()
            let response = try await session.translate(request.text)
            service.complete(request: request, result: response.targetText)
        } catch {
            Log.ui.error("Translation failed: \(String(describing: error), privacy: .public)")
            // Resolve rather than retry: the caller falls back to the original.
            service.complete(request: request, result: nil)
        }
    }
}
