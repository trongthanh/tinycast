import SwiftUI

struct DictionaryScreen: PaletteScreen {
    let session: DictionarySession
    let core: AppCore
    let vm: PaletteState

    enum Row: Identifiable {
        case entry(DictionaryEntry)
        case suggestion(DictionaryLookup.Suggestion)

        var term: String {
            switch self {
            case .entry(let entry): entry.term
            case .suggestion(let suggestion): suggestion.term
            }
        }

        var id: String {
            switch self {
            case .entry: "entry:\(term)"
            case .suggestion: "suggestion:\(term)"
            }
        }
    }

    private var term: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var entry: DictionaryEntry? { session.lookup?.entry }

    var rows: [Row] {
        if let entry { return [.entry(entry)] }
        return (session.lookup?.suggestions ?? []).map(Row.suggestion)
    }

    var primaryActionTitle: String { entry == nil ? "Show Details" : "Copy Definition" }

    private func row(at selection: Int) -> Row? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let row = row(at: selection) else { return nil }
        let primary: PopoverMenuItem
        switch row {
        case .entry(let entry):
            primary = PopoverMenuItem(
                title: "Copy Definition", systemImage: "doc.on.doc", shortcut: "↵"
            ) { core.dictionaryCoordinator.copy(entry) }
        case .suggestion(let suggestion):
            primary = PopoverMenuItem(
                title: "Show Details", systemImage: "character.book.closed", shortcut: "↵"
            ) { vm.rewriteQuery(suggestion.term) }
        }
        return PopoverMenuContent(
            header: row.term,
            items: [
                primary,
                PopoverMenuItem(title: "Copy Word", systemImage: "doc.on.doc", shortcut: "⌥↵") {
                    core.dictionaryCoordinator.copyWord(row.term)
                },
                PopoverMenuItem(title: "Open in Dictionary", systemImage: "book", shortcut: "⌘↵") {
                    core.dictionaryCoordinator.openInDictionary(term: row.term)
                }
            ])
    }

    func activate(at selection: Int) {
        guard let row = row(at: selection) else { return }
        switch row {
        case .entry(let entry): core.dictionaryCoordinator.copy(entry)
        case .suggestion(let suggestion): vm.rewriteQuery(suggestion.term)
        }
    }

    func secondary(at selection: Int) -> Bool {
        guard let row = row(at: selection) else { return false }
        core.dictionaryCoordinator.openInDictionary(term: row.term)
        return true
    }

    func optionReturn(at selection: Int) -> Bool {
        guard let row = row(at: selection) else { return false }
        core.dictionaryCoordinator.copyWord(row.term)
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        if term.isEmpty { return AnyView(EmptyResults(text: "Type a word to define")) }
        if let entry { return AnyView(DictionaryEntryView(entry: entry)) }
        if let lookup = session.lookup, !lookup.suggestions.isEmpty {
            return AnyView(
                DictionarySuggestionsView(
                    suggestions: lookup.suggestions,
                    selectedTerm: row(at: selection)?.term, scroll: scroll,
                    onActivate: { vm.rewriteQuery($0) }))
        }
        if session.lookup != nil { return AnyView(EmptyResults(text: "No definition found")) }
        return AnyView(Color.clear)
    }
}
