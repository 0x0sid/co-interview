import Testing
@testable import prompter

struct TokenizerTests {
    @Test
    func normalizeWordLowercasesFoldsAndStripsPunctuation() {
        #expect(Tokenizer.normalizeWord("Café,") == "cafe")
        #expect(Tokenizer.normalizeWord("DON'T") == "dont")
        #expect(Tokenizer.normalizeWord("naïve") == "naive")
        #expect(Tokenizer.normalizeWord("hello") == "hello")
    }

    @Test
    func normalizeSplitsOnWhitespaceAndDropsEmptyResults() {
        #expect(Tokenizer.normalize("Hello,   world! -- ") == ["hello", "world"])
    }
}
