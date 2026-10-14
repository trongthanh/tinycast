# Dictionary

`Define Word` is a launcher command and a fallback. The command opens the dictionary screen (`.dictionary`)
empty; the fallback opens it on whatever was typed. The search field stays the term, so a different
word is one edit away. Definitions come from the dictionaries enabled in Dictionary.app; near misses
come from macOS's native spelling candidates, filtered to words those dictionaries can define — no
network, no bundled word list.

## Invariants

- **The command gates the fallback, never the reverse.** Define Word has no feature pane, so
  Settings › Commands is its switch: while the command is hidden there — itself or the whole Commands
  category — `FallbackCoordinator` offers no Define Word fallback and Settings › Fallbacks does not
  list it. While it is visible, the fallback's own checkbox hides just the fallback, leaving the
  command searchable.
- **The page comes from an undocumented call, resolved at run time.** The public
  `DCSCopyTextDefinition` returns one unbroken line, so `DictionaryService` asks for the record's XHTML
  through `DCSGetActiveDictionaries`, `DCSCopyRecordsForSearchString` and `DCSRecordCopyData` — what
  Dictionary.app itself reads. They are found with `dlsym`, never linked: a macOS that drops one loses
  the layout and falls back to the public plain text, rather than failing to launch.
- **The span classes are the only structure, and `DictionaryMarkup` is the only reader of them.**
  `hg` is the headword, `posg` the part of speech, `se2` a numbered sense, `msDict` its definition or a
  `t_subsense` bullet, `note` an aside, `x_xoLblBlk` a section label (`ORIGIN`, `PHRASES`). Unknown
  markup reads as plain text in the nearest block, so a format change degrades rather than drops words.
  `dictionary-test` holds a real record as its fixture.
- **Dictionary reads run off the main actor.** A long entry (`run`, `take`) is a few hundred blocks,
  so `DictionarySession` debounces the query and `DictionaryService.lookUp` runs concurrently. Spelling
  candidates use `NSSpellChecker.requestCandidates`' background callback, without blocking the main
  actor; its stream follows cancellation. The session rejects canceled or superseded results.
  The previous definition or suggestion list stays up until the next resolves, and every action acts
  on what is shown, so neither the content nor the footer flickers while typing.
- **Exact definitions win; corrections are never automatic.** Only a term with no definition shows
  “Did you mean?”. `DictionaryLookup` trims and deduplicates candidates case-insensitively, preserving
  the native ranking and accents. The service checks that each candidate has a definition before
  retaining up to eight, each with a single-line definition preview including pronunciation and
  part of speech when available. The preview comes from the same plain-text definition used to verify
  the candidate; whitespace is collapsed and a repeated keyword is omitted. Selecting one rewrites
  the search field and looks it up; it never copies an unrelated definition or silently changes the query.

## Actions

| Key | Does |
| --- | --- |
| ↑ / ↓ | Select a spelling candidate when suggestions are shown |
| ↵ / click | Show Details for the selected candidate; on a definition, ↵ copies the whole entry and closes the palette |
| ⌥↵ | Copy Word — just the selected candidate or displayed definition's keyword, then close the palette |
| ⌘↵ | Open the displayed definition or selected candidate in Dictionary — `dict://<term>` |

⌘K offers the same actions for the displayed definition or selected candidate.

The first enabled dictionary that knows the term answers, in Dictionary.app's own order. A term none of
them knows shows selectable spelling candidates when available, or “No definition found” otherwise.
The spelling language follows macOS's spelling preferences; candidate availability can vary with
those preferences and the dictionaries installed on the Mac.
