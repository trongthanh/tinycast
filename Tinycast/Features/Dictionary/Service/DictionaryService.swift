import AppKit
import CoreServices
import Darwin

/// Looks a term up in the dictionaries enabled in Dictionary.app, entirely on this Mac.
enum DictionaryService {
    @concurrent
    static func lookUp(_ term: String) async -> DictionaryLookup {
        guard !term.isEmpty, !Task.isCancelled else {
            return DictionaryLookup(term: term, entry: nil)
        }
        if let entry = entry(for: term) { return DictionaryLookup(term: term, entry: entry) }
        let guesses = await spellingCandidates(for: term)
        var suggestions: [DictionaryLookup.Suggestion] = []
        for candidate in DictionaryLookup.candidates(for: term, from: guesses) {
            guard !Task.isCancelled else { break }
            guard let definition = plainText(for: candidate) else { continue }
            suggestions.append(DictionaryLookup.Suggestion(term: candidate, definition: definition))
            if suggestions.count == DictionaryLookup.suggestionLimit { break }
        }
        return DictionaryLookup(term: term, entry: nil, suggestions: suggestions)
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
    nonisolated static func entry(for term: String) -> DictionaryEntry? {
        if let blocks = DictionaryRecords.resolved?.blocks(for: term) {
            return DictionaryEntry(term: term, blocks: blocks)
        }
        return plainText(for: term).map { DictionaryEntry(term: term, plainText: $0) }
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

    /// `DCSRecordCopyData`'s XHTML version; the plain-text one is what the public API returns.
    private static let xhtml: CFIndex = 0

    private let activeDictionaries: ActiveDictionaries
    private let copyRecords: CopyRecords
    private let copyData: CopyData

    /// Looked up at run time: a macOS that drops a symbol loses the layout, not the launch.
    static let resolved: DictionaryRecords? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let active = dlsym(rtldDefault, "DCSGetActiveDictionaries"),
            let records = dlsym(rtldDefault, "DCSCopyRecordsForSearchString"),
            let data = dlsym(rtldDefault, "DCSRecordCopyData")
        else { return nil }
        return DictionaryRecords(
            activeDictionaries: unsafeBitCast(active, to: ActiveDictionaries.self),
            copyRecords: unsafeBitCast(records, to: CopyRecords.self),
            copyData: unsafeBitCast(data, to: CopyData.self))
    }()

    /// The first enabled dictionary that knows the term, in Dictionary.app's own order.
    func blocks(for term: String) -> [DictionaryEntry.Block]? {
        guard let dictionaries = activeDictionaries()?.takeUnretainedValue() as? [DCSDictionary]
        else { return nil }
        for dictionary in dictionaries {
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
}
