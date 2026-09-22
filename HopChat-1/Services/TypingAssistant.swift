//
//  TypingAssistant.swift
//  HopChat-1
//
//  Gentle, correctable typing suggestions for the chat composer.
//
//  Everything here runs **on device** through `UITextChecker` (the same
//  dictionaries the keyboard uses). Nothing is sent anywhere: the app is
//  end-to-end encrypted, and a cloud spell-checker would be a privacy
//  regression, so this file must never gain a network dependency.
//
//  The assistant only ever looks at the word the writer is on (or has just
//  finished) and it never rewrites anything by itself — the view shows the
//  guesses and the writer taps one.
//

import Foundation
import UIKit

// MARK: - Suggestion

/// One correctable word in a draft.
nonisolated struct TypingSuggestion: Equatable {

    enum Kind: Equatable {
        /// The word is misspelled; `replacements` are `UITextChecker` guesses.
        case misspelling
        /// The word is a prefix of longer words; `replacements` complete it.
        case completion
    }

    /// Range of `original` inside the text it was produced from.
    let range: Range<String.Index>
    /// The word as the writer typed it.
    let original: String
    /// Up to three offered replacements, best first.
    let replacements: [String]
    let kind: Kind

    /// Replaces `suggestion.range` in `text` with `replacement`.
    ///
    /// String indices are only valid for the string they came from, so this
    /// guards the range before using it and returns `text` unchanged when it
    /// no longer fits (the draft moved on while the bar was visible).
    static func apply(_ suggestion: TypingSuggestion,
                      replacement: String,
                      to text: String) -> String {
        let range = suggestion.range
        guard range.lowerBound >= text.startIndex,
              range.upperBound <= text.endIndex,
              range.lowerBound <= range.upperBound else { return text }
        // The draft may have changed under the same indices.
        guard String(text[range]) == suggestion.original else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }
}

// MARK: - Spell checking

/// The slice of `UITextChecker` this file uses. It exists so the logic above
/// it can be tested without the system dictionaries: a simulator often has no
/// linguistic data at all, and then every real lookup returns "nothing is
/// misspelled", which would quietly pass any test written against it.
@MainActor
protocol SpellChecking {
    var languages: [String] { get }
    func misspelledRange(in text: String, startingAt offset: Int, language: String) -> NSRange
    func spellGuesses(forWordRange range: NSRange, in text: String, language: String) -> [String]
    func spellCompletions(forPartialWordRange range: NSRange, in text: String, language: String) -> [String]
}

extension UITextChecker: SpellChecking {
    var languages: [String] { UITextChecker.availableLanguages }

    func misspelledRange(in text: String, startingAt offset: Int, language: String) -> NSRange {
        // The searched range must *begin* at `offset`. Passing the whole text
        // and relying on `startingAt:` to resume mid-string does not work:
        // measured on iOS 27, range {0, len} with startingAt 7 reports "no
        // misspelling" for "I will recieve ", while a range beginning at 7
        // finds it. Scoping the range is what makes the real checker agree
        // with the stand-in used in the tests.
        let length = (text as NSString).length
        let start = max(0, min(offset, length))
        return rangeOfMisspelledWord(in: text,
                                     range: NSRange(location: start, length: length - start),
                                     startingAt: start,
                                     wrap: false,
                                     language: language)
    }

    // Distinct names: overloading the real methods on return type alone
    // invites the compiler to pick the wrong one (and recurse).
    func spellGuesses(forWordRange range: NSRange, in text: String, language: String) -> [String] {
        guesses(forWordRange: range, in: text, language: language) ?? []
    }

    func spellCompletions(forPartialWordRange range: NSRange, in text: String, language: String) -> [String] {
        completions(forPartialWordRange: range, in: text, language: language) ?? []
    }
}

// MARK: - Assistant

/// Wraps `UITextChecker`. Pure and synchronous — call it from the view after
/// a debounce; a single lookup on a short draft is cheap.
@MainActor
final class TypingAssistant {

    static let shared = TypingAssistant()

    /// One checker is reused: it caches its dictionaries.
    private let checker: SpellChecking

    /// At most this many replacements are offered.
    static let maxReplacements = 3

    /// Longest draft we bother checking. Composer drafts are short and we only
    /// look at the last word anyway; this bounds the work on a pasted essay.
    private static let maxScanLength = 2_000

    init(checker: SpellChecking? = nil) {
        // Built here rather than in a default argument, which is evaluated
        // outside the main actor.
        self.checker = checker ?? UITextChecker()
    }

    // MARK: Language resolution

    /// The language the writer is most likely typing in, as a BCP-47 code.
    ///
    /// In order: the chat's auto-translate language if one is set, then the
    /// app language setting, then `Locale.current`.
    static func resolvedLanguage(conversationLanguage: String?,
                                 appLanguage: String?,
                                 locale: Locale = .current) -> String {
        let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let chat = conversationLanguage.map(trim), !chat.isEmpty { return chat }
        if let app = appLanguage.map(trim), !app.isEmpty { return app }
        return locale.identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// Maps a loose code ("pt", "pt-PT", "pt_BR", "en-US") onto something
    /// `UITextChecker` actually has, or `nil` when it has nothing for it.
    ///
    /// Never falls back to English: suggesting English corrections for
    /// Portuguese text is worse than suggesting nothing.
    static func checkerLanguage(for code: String,
                                available: [String] = UITextChecker.availableLanguages) -> String? {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        // `availableLanguages` uses underscores ("pt_PT"); callers may pass
        // either separator, so both sides are normalized before comparing.
        // Getting this wrong once sent "pt-PT" to the Brazilian dictionary.
        let canonical = { (code: String) in
            code.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        if let exact = available.first(where: { canonical($0) == canonical(normalized) }) {
            return exact
        }

        let base = normalized.split(separator: "-").first.map(String.init)?.lowercased()
        guard let base, !base.isEmpty else { return nil }

        // A regional variant of the same base language ("pt" → "pt_PT").
        if let regional = available.first(where: {
            $0.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first?.lowercased() == base
        }) {
            return regional
        }
        return nil
    }

    // MARK: Suggestions

    /// The one suggestion worth showing for `text`, or `nil`.
    ///
    /// `language` is a loose code; it is resolved against
    /// `UITextChecker.availableLanguages` and no suggestion is produced when
    /// the language isn't installed.
    func suggestion(for text: String, language: String) -> TypingSuggestion? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.count <= Self.maxScanLength else { return nil }
        guard let checkerLanguage = Self.checkerLanguage(for: language,
                                                         available: checker.languages) else { return nil }

        guard let word = Self.currentWord(in: text) else { return nil }
        let nsRange = NSRange(word.range, in: text)
        guard nsRange.location != NSNotFound else { return nil }

        // 1. Is the word itself misspelled?
        let misspelled = checker.misspelledRange(in: text,
                                                 startingAt: nsRange.location,
                                                 language: checkerLanguage)
        if misspelled.location != NSNotFound,
           NSIntersectionRange(misspelled, nsRange).length > 0 || misspelled.location == nsRange.location,
           let range = Range(misspelled, in: text) {
            let original = String(text[range])
            let guesses = checker.spellGuesses(forWordRange: misspelled,
                                          in: text,
                                          language: checkerLanguage)
            let replacements = Self.clean(guesses, dropping: original)
            guard !replacements.isEmpty else { return nil }
            return TypingSuggestion(range: range,
                                    original: original,
                                    replacements: replacements,
                                    kind: .misspelling)
        }

        // 2. Half-typed but spelled correctly so far — offer completions, but
        //    only while the writer is still on the word (no trailing space).
        guard word.isAtCaret, word.text.count >= 3 else { return nil }
        let completions = checker.spellCompletions(forPartialWordRange: nsRange,
                                              in: text,
                                              language: checkerLanguage)
        let replacements = Self.clean(completions, dropping: word.text)
        guard !replacements.isEmpty else { return nil }
        return TypingSuggestion(range: word.range,
                                original: word.text,
                                replacements: replacements,
                                kind: .completion)
    }

    // MARK: Word extraction

    struct CurrentWord {
        let text: String
        let range: Range<String.Index>
        /// `true` when the word runs to the very end of the draft, i.e. the
        /// writer is still typing it rather than having finished it.
        let isAtCaret: Bool
    }

    /// The word the writer is on, or the one they just finished.
    ///
    /// Trailing whitespace and punctuation are skipped, so "teh " and "teh."
    /// both resolve to "teh". Returns `nil` when the tail holds no letters.
    static func currentWord(in text: String) -> CurrentWord? {
        let isWordCharacter: (Character) -> Bool = { ch in
            ch.isLetter || ch == "'" || ch == "’" || ch == "-"
        }

        var end = text.endIndex
        var trimmedTail = false
        while end > text.startIndex {
            let previous = text.index(before: end)
            if isWordCharacter(text[previous]) { break }
            trimmedTail = true
            end = previous
        }
        guard end > text.startIndex else { return nil }

        var start = end
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard isWordCharacter(text[previous]) else { break }
            start = previous
        }
        let range = start..<end
        let word = String(text[range])
        guard word.contains(where: { $0.isLetter }) else { return nil }
        return CurrentWord(text: word, range: range, isAtCaret: !trimmedTail)
    }

    /// De-duplicates, drops the word itself, and caps the list.
    private static func clean(_ candidates: [String], dropping original: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only an exact match is dropped: "nao" → "não" differs by a
            // diacritic and is exactly the correction we want to offer.
            guard !trimmed.isEmpty,
                  trimmed != original,
                  seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == maxReplacements { break }
        }
        return result
    }
}
