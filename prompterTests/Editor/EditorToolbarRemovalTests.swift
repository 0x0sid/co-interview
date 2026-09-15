import Testing
import Foundation
@testable import prompter

/// **M5.10 — the editor's A / A / [ ] toolbar is gone, and user text is untouched.**
///
/// Source-level assertions, because the point is that the *controls* no longer exist: a UI test
/// could only show they are not visible, not that the insertion action was removed rather than
/// hidden or relocated into a menu.
struct EditorToolbarRemovalTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Editor
            .deletingLastPathComponent()      // prompterTests
            .deletingLastPathComponent()      // repo root
    }

    private var editorSource: String {
        let url = repoRoot.appendingPathComponent("prompter/Editor/ScriptEditorScreen.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test
    func theEditorSourceIsReadable() {
        #expect(!editorSource.isEmpty, "could not read ScriptEditorScreen.swift")
    }

    @Test
    func theFontAndPauseControlsAreRemoved() {
        let source = editorSource
        for symbol in ["textformat.size.smaller", "textformat.size.larger",
                       "editorFontScale", "toolboxButton", "private var toolbox",
                       "insertBracketPlaceholder"] {
            #expect(!source.contains(symbol), "\(symbol) is still present in the editor")
        }
        #expect(!source.contains("Divider()"), "the toolbar divider is still present")
    }

    /// The insertion action must not have been relocated into a menu or toolbar elsewhere.
    @Test
    func thePauseInsertionActionWasNotRelocated() {
        let root = repoRoot.appendingPathComponent("prompter")
        var offenders: [String] = []
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    if trimmed.contains("\"[pause]\"") {
                        offenders.append("\(url.lastPathComponent): \(trimmed.prefix(70))")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "pause-marker insertion still exists: \(offenders)")
    }

    /// **Existing script text is preserved.** Removing the way to insert a marker must not strip
    /// markers from documents that already contain them, rewrite titles, or repair stored scripts.
    @Test
    func existingPauseMarkersInStoredTextArePreserved() {
        let damaged = "[pause]ot just [pause]one or two lines.\n\nAs you speak, the current sentence should highlight."
        let script = Script(title: "", rawText: damaged)
        #expect(script.rawText == damaged, "stored script text was rewritten")
        #expect(script.rawText.contains("[pause]ot just"), "a marker was stripped from user text")
        // **Tokenization of this text changed in M5.12, deliberately.** `Tokenizer.normalize` now uses
        // ICU word segmentation (the same segmenter the script side always used), and ICU treats the
        // bracket as a word boundary:
        //
        //     before (whitespace split) : ["pauseot", "just", ...]
        //     after  (ICU .byWords)     : ["pause", "ot", "just", ...]
        //
        // The invariant this test exists for is unaffected — the **stored text** is byte-identical,
        // asserted above. What moved is how a bracketed marker is split for matching, and the new
        // split is the more defensible one: the marker is isolated instead of fused to the following
        // word. Recorded rather than pinned to the old value.
        let tokens = Tokenizer.normalize(damaged)
        #expect(tokens.prefix(3) == ["pause", "ot", "just"],
                "tokenization of existing user text changed unexpectedly: \(tokens.prefix(3))")
    }
}
