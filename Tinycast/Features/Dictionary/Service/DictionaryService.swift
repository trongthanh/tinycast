import AppKit
import CoreServices
import Darwin
import Foundation

/// Looks a term up in the dictionaries enabled in Dictionary.app, entirely on this Mac.
enum DictionaryService {
    @concurrent
    static func lookUp(_ term: String, _ scope: DictionaryScope) async -> DictionaryLookup {
        guard !term.isEmpty, !Task.isCancelled else {
            return DictionaryLookup(term: term, scope: scope, entry: nil)
        }
        if let matches = DictionaryRecords.resolved?.accentVariants(for: term, in: scope), matches.count > 1 {
            let variants = matches.map {
                DictionaryLookup.Suggestion(term: $0.term, definition: $0.text, entry: $0)
            }
            let completions = await completions(for: term)
            var suggestions: [DictionaryLookup.Suggestion] = []
            var seen = Set(variants.map { $0.term.lowercased() })
            for candidate in completions {
                guard !Task.isCancelled, suggestions.count < 5 else { break }
                guard seen.insert(candidate.lowercased()).inserted,
                    let entry = entry(for: candidate, in: scope) else { continue }
                suggestions.append(.init(term: candidate, definition: entry.text, entry: entry))
            }
            return DictionaryLookup(term: term, scope: scope, entry: nil, suggestions: suggestions + variants)
        }
        if let entry = entry(for: term, in: scope) {
            return DictionaryLookup(term: term, scope: scope, entry: entry)
        }
        let guesses = await spellingCandidates(for: term)
        var suggestions: [DictionaryLookup.Suggestion] = []
        for candidate in DictionaryLookup.candidates(for: term, from: guesses) {
            guard !Task.isCancelled else { break }
            let definition = scope == .dictionary
                ? plainText(for: candidate) : entry(for: candidate, in: scope)?.text
            guard let definition else { continue }
            suggestions.append(DictionaryLookup.Suggestion(term: candidate, definition: definition))
            if suggestions.count == DictionaryLookup.suggestionLimit { break }
        }
        return DictionaryLookup(term: term, scope: scope, entry: nil, suggestions: suggestions)
    }

    @MainActor
    private static func completions(for term: String) -> [String] {
        let range = NSRange(location: 0, length: term.utf16.count)
        return NSSpellChecker.shared.completions(
            forPartialWordRange: range, in: term, language: "en_US", inSpellDocumentWithTag: 0) ?? []
    }

    @MainActor
    private static func spellingCandidates(for term: String) async -> [String] {
        guard !Task.isCancelled else { return [] }
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        let range = NSRange(location: 0, length: term.utf16.count)
        let candidates = AsyncStream<[String]>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            checker.requestCandidates(
                forSelectedRange: range, in: term,
                types: NSTextCheckingResult.CheckingType.correction.rawValue,
                options: [:], inSpellDocumentWithTag: tag
            ) { @Sendable _, results in
                let words = results.filter { $0.range == range }.compactMap(\.replacementString)
                continuation.yield(words)
                continuation.finish()
            }
        }
        for await words in candidates { return words }
        return []
    }

    /// Blocking and parse-heavy for a long entry, so the session runs it off the main actor.
    nonisolated static func entry(for term: String, in scope: DictionaryScope) -> DictionaryEntry? {
        if let blocks = DictionaryRecords.resolved?.blocks(for: term, in: scope) {
            return DictionaryEntry(term: term, blocks: blocks)
        }
        // The public call reads every enabled dictionary, so it cannot answer for the thesauri alone.
        guard scope == .dictionary else { return nil }
        return plainText(for: term).map { DictionaryEntry(term: term, plainText: $0) }
    }

    nonisolated static func hasThesaurus() -> Bool {
        DictionaryRecords.resolved?.hasThesaurus() ?? false
    }

    private nonisolated static func plainText(for term: String) -> String? {
        let range = CFRange(location: 0, length: term.utf16.count)
        guard let text = DCSCopyTextDefinition(nil, term as CFString, range)?.takeRetainedValue()
        else { return nil }
        let trimmed = (text as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Dictionary Services' record calls: what Dictionary.app reads, though no header declares them.
private struct DictionaryRecords: Sendable {
    private typealias ActiveDictionaries = @convention(c) () -> Unmanaged<CFArray>?
    private typealias CopyRecords =
        @convention(c) (
            DCSDictionary, CFString, UnsafeRawPointer?, UnsafeRawPointer?
        ) -> Unmanaged<CFArray>?
    private typealias CopyData = @convention(c) (CFTypeRef, CFIndex) -> Unmanaged<CFString>?
    private typealias GetURL = @convention(c) (DCSDictionary) -> Unmanaged<CFURL>?

    /// `DCSRecordCopyData`'s XHTML version; the plain-text one is what the public API returns.
    private static let xhtml: CFIndex = 0

    private let activeDictionaries: ActiveDictionaries
    private let copyRecords: CopyRecords
    private let copyData: CopyData
    private let url: GetURL

    /// Looked up at run time: a macOS that drops a symbol loses the layout, not the launch.
    static let resolved: DictionaryRecords? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let active = dlsym(rtldDefault, "DCSGetActiveDictionaries"),
            let records = dlsym(rtldDefault, "DCSCopyRecordsForSearchString"),
            let data = dlsym(rtldDefault, "DCSRecordCopyData"),
            let url = dlsym(rtldDefault, "DCSDictionaryGetURL")
        else { return nil }
        return DictionaryRecords(
            activeDictionaries: unsafeBitCast(active, to: ActiveDictionaries.self),
            copyRecords: unsafeBitCast(records, to: CopyRecords.self),
            copyData: unsafeBitCast(data, to: CopyData.self),
            url: unsafeBitCast(url, to: GetURL.self))
    }()

    func hasThesaurus() -> Bool {
        dictionaries().contains(where: isThesaurus)
    }

    func accentVariants(for term: String, in scope: DictionaryScope) -> [DictionaryEntry]? {
        let query = term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        for dictionary in dictionaries() {
            if scope == .thesaurus, !isThesaurus(dictionary) { continue }
            guard let records = copyRecords(dictionary, term as CFString, nil, nil)?
                .takeRetainedValue() as? [CFTypeRef], !records.isEmpty else { continue }
            var entries: [DictionaryEntry] = []
            for record in records {
                guard let xhtml = copyData(record, Self.xhtml)?.takeRetainedValue() as String?,
                    let parsed = DictionaryMarkup.record(fromXHTML: xhtml) else { continue }
                guard parsed.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    == query else { continue }
                if let index = entries.firstIndex(where: { $0.term == parsed.title }) {
                    let previous = entries[index]
                    entries[index] = DictionaryEntry(term: previous.term, blocks: previous.blocks + parsed.blocks)
                } else {
                    entries.append(DictionaryEntry(term: parsed.title, blocks: parsed.blocks))
                }
            }
            return entries
        }
        return nil
    }

    /// The first enabled dictionary in scope that knows the term, in Dictionary.app's own order.
    func blocks(for term: String, in scope: DictionaryScope) -> [DictionaryEntry.Block]? {
        for dictionary in dictionaries() {
            if scope == .thesaurus, !isThesaurus(dictionary) { continue }
            guard
                let records = copyRecords(dictionary, term as CFString, nil, nil)?
                    .takeRetainedValue() as? [CFTypeRef]
            else { continue }
            let blocks = records.flatMap { record in
                (copyData(record, Self.xhtml)?.takeRetainedValue() as String?)
                    .map(DictionaryMarkup.blocks(fromXHTML:)) ?? []
            }
            if !blocks.isEmpty { return blocks }
        }
        return nil
    }

    private func dictionaries() -> [DCSDictionary] {
        activeDictionaries()?.takeUnretainedValue() as? [DCSDictionary] ?? []
    }

    /// No key marks a thesaurus, but every one Apple ships names itself so in `CFBundleName`.
    private func isThesaurus(_ dictionary: DCSDictionary) -> Bool {
        guard let location = url(dictionary)?.takeUnretainedValue() as URL?,
            let name = Bundle(url: location)?.object(forInfoDictionaryKey: "CFBundleName") as? String
        else { return false }
        return name.contains("Thesaurus")
    }
}
