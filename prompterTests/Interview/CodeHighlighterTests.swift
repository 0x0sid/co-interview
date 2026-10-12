import Foundation
import Testing
@testable import neverblank

/// Code samples are coloured by their fence's language, and the language survives saving.
struct CodeHighlighterTests {
    static func kinds(_ code: String, _ language: String?) -> [String: CodeHighlighter.Kind] {
        var map: [String: CodeHighlighter.Kind] = [:]
        for token in CodeHighlighter.tokens(code, language: language) where token.kind != .plain {
            map[token.text] = token.kind
        }
        return map
    }

    @Test
    func javaKeywordsTypesStringsNumbersCallsAndComments() {
        let k = Self.kinds("public static int count(List<String> xs) { return xs.size() + 42; } // total\nString s = \"hi\";", "java")
        #expect(k["public"] == .keyword && k["static"] == .keyword && k["int"] == .keyword && k["return"] == .keyword)
        #expect(k["List"] == .type && k["String"] == .type)
        #expect(k["count"] == .function && k["size"] == .function)
        #expect(k["42"] == .number && k["\"hi\""] == .string && k["// total"] == .comment)
    }

    @Test
    func pythonUsesHashCommentsAndItsOwnKeywords() {
        let k = Self.kinds("def area(r):  # circle\n    return 3.14 * r ** 2", "python")
        #expect(k["def"] == .keyword && k["return"] == .keyword)
        #expect(k["# circle"] == .comment && k["area"] == .function && k["3.14"] == .number)
    }

    @Test
    func cppDirectivesAreNotComments() {
        let k = Self.kinds("#include <vector>\nint main() { std::vector<int> v; }", "cpp")
        #expect(k["#include"] == .keyword && k["int"] == .keyword && k["main"] == .function)
    }

    @Test
    func sqlKeywordsInAnyCase() {
        let k = Self.kinds("SELECT name FROM users -- active only\nwhere id = 7", "sql")
        #expect(k["SELECT"] == .keyword && k["FROM"] == .keyword && k["where"] == .keyword)
        #expect(k["-- active only"] == .comment && k["7"] == .number)
    }

    @Test
    func anUnclosedStringFromAHalfStreamedBlockDoesNotCrash() {
        let tokens = CodeHighlighter.tokens("let s = \"unfinished", language: "swift")
        #expect(tokens.map(\.text).joined() == "let s = \"unfinished", "every character is kept, in order")
    }

    @Test
    func theFenceLanguageIsKeptAndSaved() {
        let blocks = AnswerBlock.parsed(from: "Here:\n```java\nint x = 1;\n```\nDone.")
        #expect(blocks.contains(.code("int x = 1;", language: "java")))
        #expect(StoredBlock.decode(StoredBlock.encode(blocks)) == blocks)
        let untagged = AnswerBlock.parsed(from: "```\nx = 1\n```")
        #expect(untagged == [.code("x = 1", language: nil)])
        // An answer saved before languages were kept still loads.
        let old = Data(#"[{"kind":"code","text":"x = 1"}]"#.utf8)
        #expect(StoredBlock.decode(old) == [.code("x = 1")])
    }
}
