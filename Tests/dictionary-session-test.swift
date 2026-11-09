import Foundation

@main
@MainActor
struct DictionarySessionTests {
    private static var failures = 0
    private static var passes = 0

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(false, "lookup settled within one second")
    }

    @MainActor
    private final class Resolver {
        var requests: [String] = []
        var completions: [String] = []
        var pending: [String: CheckedContinuation<DictionaryLookup, Never>] = [:]

        func resolve(_ term: String) async -> DictionaryLookup {
            requests.append(term)
            let result = await withCheckedContinuation { pending[term] = $0 }
            completions.append(term)
            return result
        }

        func finish(_ result: DictionaryLookup) {
            pending.removeValue(forKey: result.term)?.resume(returning: result)
        }
    }

    @MainActor
    private final class ScopedResolver {
        var pending: [DictionaryScope: CheckedContinuation<DictionaryLookup, Never>] = [:]

        func resolve(_ term: String, scope: DictionaryScope) async -> DictionaryLookup {
            await withCheckedContinuation { pending[scope] = $0 }
        }

        func finish(_ scope: DictionaryScope) {
            pending.removeValue(forKey: scope)?.resume(
                returning: DictionaryLookup(term: "word", scope: scope, entry: nil))
        }
    }

    static func main() async {
        let resolver = Resolver()
        let session = DictionarySession { term, _ in await resolver.resolve(term) }
        let mango = DictionaryLookup(
            term: "mango", entry: DictionaryEntry(term: "mango", plainText: "a tropical fruit"))
        let miss = DictionaryLookup(
            term: "recieve", entry: nil,
            suggestions: [
                .init(term: "receive", definition: "receive verb be given"),
                .init(term: "relieve", definition: "relieve verb make less severe")
            ])
        let newer = DictionaryLookup(
            term: "definately", entry: nil,
            suggestions: [.init(term: "definitely", definition: "definitely adverb without doubt")])

        session.lookUp("  mango \n")
        await waitUntil { resolver.pending["mango"] != nil }
        expect(resolver.requests == ["mango"], "the query is trimmed before lookup")
        resolver.finish(mango)
        await waitUntil { session.lookup == mango }
        session.lookUp("mango")
        expect(resolver.requests == ["mango"], "the same term is not resolved twice")

        session.lookUp("recieve")
        await waitUntil { resolver.pending["recieve"] != nil }
        expect(session.lookup == mango, "the displayed definition stays while suggestions resolve")
        session.lookUp("definately")
        await waitUntil { resolver.pending["definately"] != nil }
        resolver.finish(newer)
        await waitUntil { session.lookup == newer }
        resolver.finish(miss)
        await waitUntil { resolver.completions.contains("recieve") }
        expect(session.lookup == newer, "an older suggestion result cannot replace the current result")

        session.lookUp("recieve")
        await waitUntil { resolver.pending["recieve"] != nil }
        session.lookUp(" \n ")
        expect(session.lookup == nil, "clearing the query clears the previous suggestions immediately")
        resolver.finish(miss)
        await waitUntil { resolver.completions.filter { $0 == "recieve" }.count == 2 }
        expect(session.lookup == nil, "a result after clearing the query stays discarded")

        session.lookUp("definately")
        await waitUntil { resolver.pending["definately"] != nil }
        session.reset()
        resolver.finish(newer)
        await waitUntil { resolver.completions.filter { $0 == "definately" }.count == 2 }
        expect(session.lookup == nil, "leaving the dictionary discards an in-flight result")

        session.lookUp("recieve")
        session.lookUp("mango")
        await waitUntil { resolver.pending["mango"] != nil }
        expect(resolver.requests.last == "mango", "rapid typing resolves the final term")
        expect(resolver.requests.filter { $0 == "recieve" }.count == 2, "debounce skips superseded queries")
        resolver.finish(mango)
        await waitUntil { session.lookup == mango }
        session.reset()

        let scoped = ScopedResolver()
        let scopedSession = DictionarySession { term, scope in await scoped.resolve(term, scope: scope) }
        scopedSession.lookUp("word")
        await waitUntil { scoped.pending[.dictionary] != nil }
        scopedSession.select(.thesaurus)
        await waitUntil { scoped.pending[.thesaurus] != nil }
        scoped.finish(.thesaurus)
        await waitUntil { scopedSession.lookup?.scope == .thesaurus }
        scoped.finish(.dictionary)
        try? await Task.sleep(for: .milliseconds(20))
        expect(scopedSession.lookup?.scope == .thesaurus, "an earlier scope cannot replace the current result")
        scopedSession.reset()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
