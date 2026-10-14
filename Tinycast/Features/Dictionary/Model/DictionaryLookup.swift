import Foundation

struct DictionaryLookup: Equatable, Sendable {
    let term: String
    let entry: DictionaryEntry?
    let suggestions: [Suggestion]

    struct Suggestion: Equatable, Identifiable, Sendable {
        let term: String
        let preview: String

        var id: String { term }

        init(term: String, definition: String) {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            self.term = term
            let words = definition.split(whereSeparator: \.isWhitespace)
            let repeatsTerm = words.first.map { $0.lowercased() == term.lowercased() } ?? false
            preview = words.dropFirst(repeatsTerm && words.count > 1 ? 1 : 0).joined(separator: " ")
        }
    }

    static let suggestionLimit = 8

    init(term: String, entry: DictionaryEntry?, suggestions: [Suggestion] = []) {
        self.term = term
        self.entry = entry
        let byTerm = Dictionary(suggestions.map { ($0.term, $0) }, uniquingKeysWith: { first, _ in first })
        self.suggestions = entry == nil ? Self.candidates(for: term, from: suggestions.map(\.term))
            .prefix(Self.suggestionLimit).compactMap { byTerm[$0] } : []
    }

    static func candidates(for term: String, from guesses: [String]) -> [String] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var seen: Set<String> = [query.lowercased()]
        return guesses.compactMap { guess in
            let word = guess.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }
}
