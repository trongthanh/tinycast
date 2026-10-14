import SwiftUI

@main
@MainActor
struct DictionaryScreenTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(false, "the lookup settles within one second")
    }

    static func main() async {
        let candidates = DictionaryLookup(
            term: "recieve", entry: nil,
            suggestions: [
                .init(term: "receive", definition: "receive verb be given"),
                .init(term: "relieve", definition: "relieve verb make less severe")
            ])
        let definition = DictionaryLookup(
            term: "receive", entry: DictionaryEntry(term: "receive", plainText: "verb be given"))
        let session = DictionarySession { term in term == "receive" ? definition : candidates }
        let palette = PaletteCoordinator()
        let coordinator = DictionaryCoordinator(paletteCoordinator: palette)
        let core = AppCore(dictionaryCoordinator: coordinator)
        let vm = PaletteState()
        vm.query = "recieve"
        session.lookUp(vm.query)
        await waitUntil { session.lookup == candidates }
        let screen = DictionaryScreen(session: session, core: core, vm: vm)

        expect(screen.rows.map(\.term) == ["receive", "relieve"], "candidate rows keep native order")
        expect(screen.primaryActionTitle == "Show Details", "Return offers details for candidates")
        screen.activate(at: 1)
        expect(vm.query == "relieve", "Return rewrites the query to the selected candidate")
        expect(Paster.copied == nil, "showing details does not copy anything")
        vm.query = "a pending query"
        let dispatched: any PaletteScreen = screen
        expect(dispatched.optionReturn(at: 1), "Option-Return is handled through the screen protocol")
        expect(Paster.copied == "relieve", "Option-Return copies the displayed candidate, not the query")
        expect(palette.hides == 1, "Copy Word closes the palette")
        expect(palette.restoreFocus == false, "copying uses the same focus behavior as Copy Definition")
        expect(!screen.optionReturn(at: -1), "a negative selection does not copy")
        expect(!screen.optionReturn(at: 2), "an out-of-range selection does not copy")
        expect(palette.hides == 1, "invalid selections have no effects")

        if let menu = screen.actions(at: 0) {
            expect(menu.header == "receive", "the menu addresses the selected candidate")
            expect(
                menu.items.map(\.title) == ["Show Details", "Copy Word", "Open in Dictionary"],
                "candidate actions include keyword copying before opening Dictionary")
            expect(menu.items.map(\.shortcut) == ["↵", "⌥↵", "⌘↵"], "menu shortcuts match keyboard actions")
            menu.items[1].action()
            expect(Paster.copied == "receive", "the menu copies the same keyword as Option-Return")
        } else {
            expect(false, "a candidate has an Actions menu")
        }
        expect(screen.secondary(at: 0), "Command-Return still opens Dictionary")
        expect(AppLauncher.opened?.absoluteString == "dict://receive", "Dictionary opens the selected term")

        vm.query = "receive"
        session.lookUp(vm.query)
        await waitUntil { session.lookup == definition }
        expect(screen.primaryActionTitle == "Copy Definition", "an exact entry keeps its primary action")
        expect(screen.optionReturn(at: 0), "Option-Return also handles an exact entry")
        expect(Paster.copied == "receive", "an exact entry copies only its keyword on Option-Return")
        screen.activate(at: 0)
        expect(Paster.copied == definition.entry?.text, "Return on an exact entry still copies its definition")

        session.reset()
        expect(!screen.optionReturn(at: 0), "an empty screen has no keyword to copy")
        expect(screen.actions(at: 0) == nil, "an empty screen has no candidate actions")
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}

@MainActor
protocol PaletteScreen {
    func optionReturn(at selection: Int) -> Bool
}

struct ScrollIntent {}

@MainActor
final class PaletteState {
    var query = ""
    func rewriteQuery(_ term: String) { query = term }
}

@MainActor
final class PaletteCoordinator {
    var hides = 0
    var restoreFocus: Bool?
    func togglePalette(mode: PaletteMode, seeding: String?) {}
    func hidePalette(restoreFocus: Bool) {
        hides += 1
        self.restoreFocus = restoreFocus
    }
}

enum PaletteMode { case dictionary }

@MainActor
struct AppCore {
    let dictionaryCoordinator: DictionaryCoordinator
}

@MainActor
enum Paster {
    static var copied: String?
    static func copyPlainText(_ text: String) { copied = text }
}

@MainActor
enum AppLauncher {
    static var opened: URL?
    static func open(_ url: URL) { opened = url }
}

struct PopoverMenuContent {
    let header: String
    let items: [PopoverMenuItem]
}

struct PopoverMenuItem {
    let title: String
    let systemImage: String
    let shortcut: String?
    let action: @MainActor () -> Void
}

struct DictionaryEntryView: View {
    let entry: DictionaryEntry
    var body: some View { Color.clear }
}

struct DictionarySuggestionsView: View {
    let suggestions: [DictionaryLookup.Suggestion]
    let selectedTerm: String?
    let scroll: ScrollIntent
    let onActivate: (String) -> Void
    var body: some View { Color.clear }
}

struct EmptyResults: View {
    let text: String
    var body: some View { Color.clear }
}
