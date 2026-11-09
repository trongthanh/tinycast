import Foundation

/// The dictionary screen's lookup: one term in flight, answered off the main actor.
@MainActor
@Observable
final class DictionarySession {
    /// The last answered lookup; it stays up while the next term resolves, so typing never blanks.
    private(set) var lookup: DictionaryLookup?
    private(set) var scope = DictionaryScope.dictionary
    private(set) var hasThesaurus = false
    @ObservationIgnored private var term = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let resolve: @Sendable (String, DictionaryScope) async -> DictionaryLookup

    /// Coalesces a burst of keystrokes into the lookup for the word they settle on.
    private static let debounce = Duration.milliseconds(90)

    init(resolve: @escaping @Sendable (String, DictionaryScope) async -> DictionaryLookup = DictionaryService.lookUp) {
        self.resolve = resolve
    }

    func refreshScopes() {
        hasThesaurus = DictionaryService.hasThesaurus()
        if !hasThesaurus { select(.dictionary) }
    }

    func select(_ scope: DictionaryScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        let query = term
        term = ""
        lookUp(query)
    }

    func lookUp(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term != self.term else { return }
        self.term = term
        task?.cancel()
        guard !term.isEmpty else {
            lookup = nil
            return
        }
        let resolve = resolve
        let scope = scope
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let lookup = await resolve(term, scope)
            guard !Task.isCancelled, let self, self.term == term, self.scope == scope else { return }
            self.lookup = lookup
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        term = ""
        lookup = nil
    }
}
