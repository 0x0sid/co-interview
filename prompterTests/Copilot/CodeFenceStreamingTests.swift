import Testing
import Foundation
@testable import prompter

/// Code examples must reach the code card, whatever way the stream is chunked.
///
/// The fixture is a real answer streamed by the deployed backend on 2026-09-24
/// (`docs/evidence/code-format-2026-09-24/captured-java-lambda-stream.json`). Before the fix, the
/// streaming assembler trimmed each sentence and re-joined them with a single space, so
/// `strings.\n\n```java` became `strings. ```java`: the opening fence left the start of its line, the
/// code rendered as prose, and the explanation after the closing fence rendered as code.
@MainActor
struct CodeFenceStreamingTests {
    private typealias Support = CopilotTestSupport

    static let capturedDeltas = [
        "Here is a Java example of a lambda expression that sorts a list of ",
        "strings.\n\n```java\nimport java.util.Arrays;\nimport java.util.List;\n\npublic class SortStrings {\n    public static void main(String[] args) {\n        List<String> names = Arrays.asList(\"",
        "Charlie\", \"Alice\", \"Bob\", \"David\");\n\n        // Using a lambda expression to sort the list alphabetically\n        names.sort((s1, s2) -> s1.compareTo(s2));\n\n        System.out.pr",
        "intln(\"Sorted names: \" + names);\n    }\n}\n```\n\nThis code defines a list of strings and then uses the `sort` method with a lambda expression. The lambda `(s1, s2) -> s1.compa",
        "reTo(s2)` compares two strings `s1` and `s2` alphabetically.\n",
    ]

    static let expectedCode = """
        import java.util.Arrays;
        import java.util.List;

        public class SortStrings {
            public static void main(String[] args) {
                List<String> names = Arrays.asList("Charlie", "Alice", "Bob", "David");

                // Using a lambda expression to sort the list alphabetically
                names.sort((s1, s2) -> s1.compareTo(s2));

                System.out.println("Sorted names: " + names);
            }
        }
        """

    private static func assemble(_ deltas: [String]) -> [AnswerBlock] {
        var assembler = StreamingAnswerAssembler()
        for delta in deltas { assembler.append(delta) }
        assembler.finish()
        return AnswerBlock.parsed(from: assembler.committedText)
    }

    private static func codeBlocks(_ blocks: [AnswerBlock]) -> [String] {
        blocks.compactMap { if case .code(let code) = $0 { return code } else { return nil } }
    }

    @Test
    func theCapturedStreamRendersItsExampleAsOneCodeCard() {
        let blocks = Self.assemble(Self.capturedDeltas)
        #expect(Self.codeBlocks(blocks) == [Self.expectedCode], "the example did not become exactly one code block, verbatim")
        guard blocks.count == 3, case .prose(let before) = blocks[0], case .prose(let after) = blocks[2] else {
            Issue.record("expected prose, code, prose — got \(blocks)")
            return
        }
        #expect(before == "Here is a Java example of a lambda expression that sorts a list of strings.")
        #expect(after.hasPrefix("This code defines a list of strings"), "the explanation after the code was not prose")
        #expect(after.contains("`sort`"), "an inline identifier left its prose sentence")
    }

    /// The same bytes, however the network happens to cut them — including a fence split between
    /// deltas — produce the same blocks, with nothing lost or repeated.
    @Test(arguments: [1, 2, 3, 5, 8, 13, 40])
    func anyChunkingProducesTheSameBlocks(size: Int) {
        let text = Self.capturedDeltas.joined()
        var deltas: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            deltas.append(String(text[index..<end]))
            index = end
        }
        #expect(Self.assemble(deltas) == Self.assemble(Self.capturedDeltas))
    }

    @Test
    func blankLinesBetweenParagraphsSurvive() {
        let blocks = Self.assemble(["First point here. ", "It continues.\n\nSecond ", "paragraph starts here. "])
        #expect(blocks == [.prose("First point here. It continues."), .prose("Second paragraph starts here.")])
    }

    /// Through the real feed and screen: one code card, and the code is not in what the reader follows.
    @Test
    func theScreenShowsACodeCardAndReadsOnlyTheProse() async throws {
        let provider = Support.StubProvider()
        provider.classifications = [DetectionResult(kind: .none, questionText: "", confidence: 0.9)]
        provider.answerChunks = Self.capturedDeltas
        let coordinator = CopilotSessionCoordinator(
            project: LiveSessionContext(language: .english),
            provider: provider,
            audio: InterviewAudioInput(makeService: { FakeTranscriptionService(results: []) }),
            generationMode: .manual
        )
        let model = InterviewScreenModel(mode: .live, feed: LiveInterviewFeed(coordinator: coordinator))
        model.start()
        coordinator.ingest(Support.finalDelta("Show me a Java example of a lambda that sorts a list of strings.", at: 1))
        try await Support.waitUntil("the line") { !model.transcript.isEmpty }
        model.generate(now: Date(timeIntervalSince1970: 1_000))
        try await Support.waitUntil("the answer") { model.questions.last?.selectedAnswer?.isComplete == true }

        let answer = try #require(model.questions.last?.selectedAnswer)
        #expect(Self.codeBlocks(answer.blocks) == [Self.expectedCode])
        #expect(!answer.proseText.contains("public static void main"), "code reached the text the reader follows")
        #expect(answer.proseText.contains("This code defines a list of strings"))
        let emphasised = AnswerKeywords.spans(in: answer.proseText)
        #expect(!emphasised.isEmpty, "keyword emphasis stopped working on the prose")
        model.stop()
    }
}
