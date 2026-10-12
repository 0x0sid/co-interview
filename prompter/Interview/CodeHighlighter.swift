import SwiftUI

/// Colours a code sample by its language — keywords, types, strings, numbers, calls and comments —
/// for the code card. A small scanner, not a parser: enough to make Java, Python, C++, JavaScript,
/// Swift, Go, Rust, SQL and shell read like an editor, never enough to fail on a half-streamed block.
///
/// The language is the fence's tag (```java). Without one, a generic C-like set is used.
enum CodeHighlighter {
    enum Kind: Equatable { case plain, keyword, type, string, number, comment, function }

    struct Token: Equatable {
        let text: String
        let kind: Kind
    }

    struct Language {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var caseInsensitive = false
        /// C and C++: a `#` at the start of a line is a directive (`#include`), not a comment.
        var hashDirectives = false
    }

    // MARK: Languages

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    private static let java = Language(keywords: words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record sealed permits yield true false null"))
    private static let kotlin = Language(keywords: words("fun val var class object interface if else when for while do return break continue try catch finally throw import package is as in null true false this super override open data sealed private public internal protected companion suspend lateinit init"))
    private static let python = Language(keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield self match case print"),
                                         lineComments: ["#"], blockComment: nil)
    private static let javascript = Language(keywords: words("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of null undefined true false interface type enum implements private public protected readonly static as from number string boolean any unknown never"))
    private static let swift = Language(keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var break case continue default defer do else fallthrough for guard if in repeat return switch where while as catch false is nil self Self super throw throws true try async await actor some any"))
    private static let cFamily = Language(keywords: words("auto break case char const continue default do double else enum extern float for goto if inline int long register return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false nullptr class namespace template typename public private protected virtual override new delete this using const_cast static_cast dynamic_cast reinterpret_cast try catch throw constexpr noexcept friend operator"),
                                          hashDirectives: true)
    private static let csharp = Language(keywords: words("using namespace class public private protected internal static void int string bool var new return if else for foreach while do switch case break continue try catch finally throw async await null true false this base override virtual abstract interface struct enum readonly const get set in out ref record"))
    private static let go = Language(keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false"))
    private static let rust = Language(keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"))
    private static let sql = Language(keywords: words("select from where insert into update delete join left right inner outer full on group by order having limit offset as and or not null is in values create table index primary key foreign references drop alter add set distinct count sum avg min max union all case when then else end begin commit rollback with exists between like asc desc"),
                                      lineComments: ["--"], caseInsensitive: true)
    private static let shell = Language(keywords: words("if then else elif fi for while until do done case esac function in return export local echo exit set unset source"),
                                        lineComments: ["#"], blockComment: nil)
    private static let ruby = Language(keywords: words("def end class module if elsif else unless while until for in do return yield begin rescue ensure raise nil true false self require attr_accessor puts"),
                                       lineComments: ["#"], blockComment: nil)
    private static let php = Language(keywords: words("function class public private protected static return if else elseif foreach for while do switch case break continue new echo null true false array namespace use try catch throw extends implements"),
                                      lineComments: ["//", "#"])
    private static let generic = Language(keywords: java.keywords.union(javascript.keywords).union(python.keywords))

    static func language(for tag: String?) -> Language {
        switch tag?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "java": java
        case "kotlin", "kt": kotlin
        case "python", "py", "python3": python
        case "javascript", "js", "jsx", "typescript", "ts", "tsx", "node": javascript
        case "swift": swift
        case "c", "cpp", "c++", "cc", "cxx", "h", "hpp", "objc", "objective-c": cFamily
        case "csharp", "cs", "c#": csharp
        case "go", "golang": go
        case "rust", "rs": rust
        case "sql", "postgres", "postgresql", "mysql", "sqlite", "plsql", "tsql": sql
        case "bash", "sh", "shell", "zsh", "console": shell
        case "ruby", "rb": ruby
        case "php": php
        default: generic
        }
    }

    // MARK: Scanning

    static func tokens(_ code: String, language tag: String?) -> [Token] {
        let language = language(for: tag)
        let chars = Array(code)
        var tokens: [Token] = []
        var plain = ""
        var i = 0
        var atLineStart = true

        func flushPlain() { if !plain.isEmpty { tokens.append(Token(text: plain, kind: .plain)); plain = "" } }
        func emit(_ end: Int, _ kind: Kind) {
            flushPlain()
            tokens.append(Token(text: String(chars[i..<end]), kind: kind))
            i = end
        }
        func starts(_ s: String, at index: Int) -> Bool {
            let needle = Array(s)
            guard index + needle.count <= chars.count else { return false }
            return Array(chars[index..<index + needle.count]) == needle
        }
        func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" { plain.append(c); i += 1; atLineStart = true; continue }
            if c == " " || c == "\t" { plain.append(c); i += 1; continue }
            let lineStart = atLineStart
            atLineStart = false

            if language.hashDirectives, lineStart, c == "#" {
                var end = i + 1
                while end < chars.count, isIdentifier(chars[end]) { end += 1 }
                emit(end, .keyword); continue
            }
            if let comment = language.lineComments.first(where: { starts($0, at: i) }) {
                _ = comment
                var end = i
                while end < chars.count, chars[end] != "\n" { end += 1 }
                emit(end, .comment); continue
            }
            if let block = language.blockComment, starts(block.open, at: i) {
                var end = i + block.open.count
                while end < chars.count, !starts(block.close, at: end) { end += 1 }
                end = min(chars.count, end + block.close.count)
                emit(end, .comment); continue
            }
            if c == "\"" || c == "'" || c == "`" {
                // Python's triple quotes run across lines; other strings end at their quote or the line.
                if c != "`", starts(String(repeating: c, count: 3), at: i) {
                    let fence = String(repeating: c, count: 3)
                    var end = i + 3
                    while end < chars.count, !starts(fence, at: end) { end += 1 }
                    emit(min(chars.count, end + 3), .string); continue
                }
                var end = i + 1
                while end < chars.count, chars[end] != c, c == "`" || chars[end] != "\n" {
                    end += chars[end] == "\\" ? 2 : 1
                }
                emit(min(chars.count, end + 1), .string); continue
            }
            if c.isNumber {
                var end = i + 1
                while end < chars.count, chars[end].isHexDigit || "xX._".contains(chars[end]) { end += 1 }
                emit(end, .number); continue
            }
            if c.isLetter || c == "_" || c == "@" || c == "$" {
                var end = i + 1
                while end < chars.count, isIdentifier(chars[end]) { end += 1 }
                let word = String(chars[i..<end])
                let key = language.caseInsensitive ? word.lowercased() : word
                var next = end
                while next < chars.count, chars[next] == " " { next += 1 }
                let kind: Kind =
                    c == "@" ? .type                                         // annotations, decorators
                    : language.keywords.contains(key) ? .keyword
                    : next < chars.count && chars[next] == "(" ? .function
                    : c.isUppercase ? .type
                    : .plain
                if kind == .plain { plain += word; i = end } else { emit(end, kind) }
                continue
            }
            plain.append(c)
            i += 1
        }
        flushPlain()
        return tokens
    }

    /// The code as coloured text for the card.
    static func attributed(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        for token in tokens(code, language: language) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = color(token.kind)
            result += piece
        }
        return result
    }

    static func color(_ kind: Kind) -> SwiftUI.Color {
        switch kind {
        case .plain: InterviewTheme.Color.codeInk
        case .keyword: InterviewTheme.Color.codeKeyword
        case .type: InterviewTheme.Color.codeType
        case .string: InterviewTheme.Color.codeString
        case .number: InterviewTheme.Color.codeNumber
        case .comment: InterviewTheme.Color.codeComment
        case .function: InterviewTheme.Color.codeFunction
        }
    }
}
