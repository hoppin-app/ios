//
//  TypingAssistantTests.swift
//  HopChat-1Tests
//
//  On-device typing suggestions.
//
//  These run against a stand-in dictionary rather than `UITextChecker`: a
//  simulator often has no linguistic data installed (the log fills with
//  "com.apple.linguisticdata" failures), and then every real lookup answers
//  "nothing is misspelled" — which would make a test written against it pass
//  for the wrong reason. The last suite uses the real checker and skips when
//  the machine has no dictionary.
//

import Testing
import Foundation
import UIKit
@testable import HopChat_1

// MARK: - Stand-in dictionary

/// Knows a handful of misspellings and completions, and nothing else.
@MainActor
private final class FakeChecker: SpellChecking {
    var languages = ["en_US", "pt_PT", "fr_FR"]
    /// language → misspelled word → corrections
    var corrections: [String: [String: [String]]] = [
        "en_US": ["recieve": ["receive"], "teh": ["the", "tech"], "wrods": ["words", "rods"]],
        "pt_PT": ["obrigadu": ["obrigado"], "nao": ["não", "nau"], "ola": ["olá"]],
    ]
    /// language → prefix → completions
    var completionsByPrefix: [String: [String: [String]]] = [
        "en_US": ["conv": ["conversation", "convert", "convince", "converge"]],
    ]

    /// Mirrors `UITextChecker`: scan forward from `offset` for a known bad word.
    func misspelledRange(in text: String, startingAt offset: Int, language: String) -> NSRange {
        let known = corrections[language] ?? [:]
        let ns = text as NSString
        var index = max(0, min(offset, ns.length))
        let letters = CharacterSet.letters
        while index < ns.length {
            let remaining = NSRange(location: index, length: ns.length - index)
            let start = ns.rangeOfCharacter(from: letters, options: [], range: remaining)
            guard start.location != NSNotFound else { break }
            var end = start.location
            while end < ns.length,
                  let scalar = UnicodeScalar(ns.character(at: end)),
                  letters.contains(scalar) {
                end += 1
            }
            let word = NSRange(location: start.location, length: end - start.location)
            if known[ns.substring(with: word).lowercased()] != nil { return word }
            index = end + 1
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func spellGuesses(forWordRange range: NSRange, in text: String, language: String) -> [String] {
        corrections[language]?[(text as NSString).substring(with: range).lowercased()] ?? []
    }

    func spellCompletions(forPartialWordRange range: NSRange, in text: String, language: String) -> [String] {
        completionsByPrefix[language]?[(text as NSString).substring(with: range).lowercased()] ?? []
    }
}

// MARK: - Suggestions

@MainActor
@Suite("TypingAssistant — suggestions")
struct TypingAssistantTests {

    private func makeAssistant() -> (TypingAssistant, FakeChecker) {
        let checker = FakeChecker()
        return (TypingAssistant(checker: checker), checker)
    }

    @Test("a misspelling is offered its correction")
    func misspelling() {
        let (assistant, _) = makeAssistant()

        let received = assistant.suggestion(for: "I will recieve ", language: "en")
        #expect(received?.kind == .misspelling)
        #expect(received?.original == "recieve")
        #expect(received?.replacements.first == "receive")

        let teh = assistant.suggestion(for: "teh", language: "en-US")
        #expect(teh?.original == "teh")
        #expect(teh?.replacements == ["the", "tech"])
    }

    @Test("Portuguese text gets Portuguese corrections")
    func portuguese() {
        let (assistant, _) = makeAssistant()

        let obrigadu = assistant.suggestion(for: "obrigadu ", language: "pt-PT")
        #expect(obrigadu?.original == "obrigadu")
        #expect(obrigadu?.replacements.contains("obrigado") == true)

        // A missing diacritic is exactly the kind of fix worth offering.
        let nao = assistant.suggestion(for: "nao", language: "pt")
        #expect(nao?.original == "nao")
        #expect(nao?.replacements.first == "não")
    }

    @Test("correct, empty and over-long text produce nothing")
    func quietWhenNothingToSay() {
        let (assistant, _) = makeAssistant()
        #expect(assistant.suggestion(for: "", language: "en") == nil)
        #expect(assistant.suggestion(for: "   \n ", language: "en") == nil)
        #expect(assistant.suggestion(for: "12345 !!!", language: "en") == nil)
        #expect(assistant.suggestion(for: "this line is spelled fine", language: "en") == nil)
        #expect(assistant.suggestion(for: String(repeating: "recieve ", count: 500), language: "en") == nil,
                "a pasted essay must not be scanned")
    }

    @Test("a language with no dictionary suggests nothing at all")
    func unknownLanguage() {
        let (assistant, _) = makeAssistant()
        // German isn't installed here: silence beats English guesses for
        // German text.
        #expect(assistant.suggestion(for: "recieve", language: "de-DE") == nil)
        #expect(assistant.suggestion(for: "recieve", language: "") == nil)
    }

    @Test("a half-typed word is completed, a finished one is not")
    func completions() {
        let (assistant, _) = makeAssistant()

        let partial = assistant.suggestion(for: "let's have a conv", language: "en")
        #expect(partial?.kind == .completion)
        #expect(partial?.original == "conv")
        #expect(partial?.replacements.count == TypingAssistant.maxReplacements,
                "at most three are offered")
        #expect(partial?.replacements.first == "conversation")

        // Once the writer typed a space the word is finished; completing it
        // would be putting words in their mouth.
        #expect(assistant.suggestion(for: "let's have a conv ", language: "en") == nil)
        // Too short to guess from.
        #expect(assistant.suggestion(for: "co", language: "en") == nil)
    }

    @Test("the word being written is the one corrected")
    func lastWordOnly() {
        let (assistant, _) = makeAssistant()
        let suggestion = assistant.suggestion(for: "I will send the wrods", language: "en")
        #expect(suggestion?.original == "wrods")
        #expect(suggestion?.replacements.first == "words")
    }

    @Test("the offered word is never the one already typed")
    func neverOffersTheSameWord() {
        let (assistant, checker) = makeAssistant()
        checker.corrections["en_US"]?["teh"] = ["teh", "the", "the", "tech"]
        let suggestion = assistant.suggestion(for: "teh", language: "en")
        #expect(suggestion?.replacements == ["the", "tech"], "duplicates and the original are dropped")
    }
}

// MARK: - Applying a suggestion

@MainActor
@Suite("TypingAssistant — applying a suggestion")
struct TypingSuggestionApplyTests {

    private func makeAssistant() -> TypingAssistant { TypingAssistant(checker: FakeChecker()) }

    @Test("applying replaces exactly the suggested word")
    func applies() throws {
        let assistant = makeAssistant()
        // The draft has to end on the misspelled word: the assistant only
        // ever looks at the word being written (or just finished).
        let draft = "I will recieve "
        let suggestion = try #require(assistant.suggestion(for: draft, language: "en"))
        #expect(TypingSuggestion.apply(suggestion, replacement: "receive", to: draft)
                == "I will receive ")
    }

    @Test("emoji and accents don't shift the replacement")
    func unicodeSafe() throws {
        let assistant = makeAssistant()
        let draft = "🇵🇹 café ☕️ obrigadu"
        let suggestion = try #require(assistant.suggestion(for: draft, language: "pt-PT"))
        #expect(suggestion.original == "obrigadu")
        #expect(TypingSuggestion.apply(suggestion, replacement: "obrigado", to: draft)
                == "🇵🇹 café ☕️ obrigado")
    }

    @Test("a stale suggestion leaves a changed draft alone")
    func staleSuggestion() throws {
        let assistant = makeAssistant()
        let draft = "I will recieve "
        let suggestion = try #require(assistant.suggestion(for: draft, language: "en"))
        // The writer kept typing, so the old range no longer holds that word.
        let moved = "oh, I will recieve "
        #expect(TypingSuggestion.apply(suggestion, replacement: "receive", to: moved) == moved)
        #expect(TypingSuggestion.apply(suggestion, replacement: "receive", to: "hi") == "hi")
    }
}

// MARK: - Language resolution

@MainActor
@Suite("TypingAssistant — language choice")
struct TypingLanguageTests {

    private let available = ["en_US", "en_GB", "pt_PT", "pt_BR", "fr_FR"]

    @Test("the chat's language wins, then the app's, then the system's")
    func order() {
        #expect(TypingAssistant.resolvedLanguage(conversationLanguage: "pt",
                                                 appLanguage: "en",
                                                 locale: Locale(identifier: "fr_FR")) == "pt")
        #expect(TypingAssistant.resolvedLanguage(conversationLanguage: nil,
                                                 appLanguage: "en",
                                                 locale: Locale(identifier: "fr_FR")) == "en")
        #expect(TypingAssistant.resolvedLanguage(conversationLanguage: nil,
                                                 appLanguage: "  ",
                                                 locale: Locale(identifier: "fr_FR")) == "fr-FR")
    }

    @Test("loose codes map onto installed dictionaries, or onto nothing")
    func mapping() {
        #expect(TypingAssistant.checkerLanguage(for: "pt-PT", available: available) == "pt_PT")
        #expect(TypingAssistant.checkerLanguage(for: "pt_PT", available: available) == "pt_PT")
        #expect(TypingAssistant.checkerLanguage(for: "en", available: available)?.hasPrefix("en") == true)
        // A region we don't have falls back to the same language, never another.
        #expect(TypingAssistant.checkerLanguage(for: "pt-MZ", available: available)?.hasPrefix("pt") == true)
        #expect(TypingAssistant.checkerLanguage(for: "de-DE", available: available) == nil)
        #expect(TypingAssistant.checkerLanguage(for: "", available: available) == nil)
    }
}

// MARK: - The real checker (skips when the machine has no dictionary)

@MainActor
@Suite("TypingAssistant — system dictionary", .serialized)
struct TypingAssistantSystemTests {

    /// True when this machine really can spell-check `language`.
    /// The simulator often detects a misspelling but has no data to correct it
    /// with, so both halves are probed before a test is taken seriously.
    private func dictionaryWorks(_ language: String, probe: String) -> Bool {
        guard let resolved = TypingAssistant.checkerLanguage(for: language) else { return false }
        let checker = UITextChecker()
        let range = checker.misspelledRange(in: probe, startingAt: 0, language: resolved)
        guard range.location != NSNotFound else { return false }
        return !checker.spellGuesses(forWordRange: range, in: probe, language: resolved).isEmpty
    }

    @Test("the system checker, when present, corrects a real misspelling")
    func systemSpelling() {
        guard dictionaryWorks("en", probe: "recieve") else {
            withKnownIssue("No English dictionary on this machine (simulators often ship none)") {
                Issue.record("skipped")
            }
            return
        }
        let suggestion = TypingAssistant().suggestion(for: "I will recieve ", language: "en")
        #expect(suggestion?.original == "recieve")
        #expect(suggestion?.replacements.contains { $0.caseInsensitiveCompare("receive") == .orderedSame } == true)
    }

    @Test("Portuguese, when present, is corrected in Portuguese")
    func systemPortuguese() {
        guard dictionaryWorks("pt-PT", probe: "obrigadu") else {
            withKnownIssue("No Portuguese dictionary on this machine") { Issue.record("skipped") }
            return
        }
        let suggestion = TypingAssistant().suggestion(for: "obrigadu ", language: "pt-PT")
        #expect(suggestion?.original == "obrigadu")
        #expect(suggestion?.replacements.isEmpty == false)
    }
}
