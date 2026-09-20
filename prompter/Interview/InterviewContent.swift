import Foundation
import SwiftUI

/// The content the interview screen shows. Plain value types with no provider, network or
/// persistence in sight: the screen is driven by an `InterviewFeed`, and this is what a feed emits.

/// One block of an answer.
///
/// **Why an answer is blocks and not one string:** the code card is excluded from speech-following,
/// and the cleanest way to guarantee that is for the aligned text never to contain it. `proseText`
/// is what the reader aligns against; `.code` blocks are rendered beside it and are not in the
/// token sequence at all.
enum AnswerBlock: Equatable, Sendable, Identifiable {
    case prose(String)
    case code(String)

    var id: String {
        switch self {
        case .prose(let text): "p:\(text)"
        case .code(let text): "c:\(text)"
        }
    }

    /// Splits generated text into prose and code **in the order it was written**.
    ///
    /// The model marks code with fenced blocks, which is the only structure the answer prompt asks
    /// for. A fence that never closes is treated as code to the end rather than dropped — text that
    /// arrived should stay visible — and everything else is prose.
    static func parsed(from text: String) -> [AnswerBlock] {
        guard text.contains("```") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : paragraphs(of: trimmed)
        }
        var blocks: [AnswerBlock] = []
        var isCode = false
        var current: [String] = []

        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            current = []
            guard !joined.isEmpty else { return }
            blocks.append(contentsOf: isCode ? [.code(joined)] : paragraphs(of: joined))
        }

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                isCode.toggle()
                continue
            }
            current.append(line)
        }
        flush()
        return blocks
    }

    /// Blank lines separate paragraphs, and each paragraph is its own prose block so the reader
    /// aligns against one paragraph at a time.
    private static func paragraphs(of text: String) -> [AnswerBlock] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { .prose($0.replacingOccurrences(of: "\n", with: " ")) }
    }
}

/// One generated answer. A question keeps every version it has had (§4: Regenerate keeps the
/// previous one), so these are appended, never replaced.
struct InterviewAnswer: Identifiable, Equatable, Sendable {
    let id: UUID
    /// 1-based. Shown as "v2 · Generated just now" once there is more than one.
    let version: Int
    var blocks: [AnswerBlock]
    /// The word the design highlights in the primary colour.
    var highlight: String?
    var isComplete: Bool
    /// Finished, but not finished *well*: generation stopped early or failed after some text had
    /// already arrived. The text stays readable and the page says so, because silently presenting a
    /// truncated answer as complete is worse than showing less.
    var isIncomplete: Bool = false
    let createdAt: Date

    init(
        id: UUID = UUID(),
        version: Int,
        blocks: [AnswerBlock] = [],
        highlight: String? = nil,
        isComplete: Bool = false,
        isIncomplete: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.version = version
        self.blocks = blocks
        self.highlight = highlight
        self.isComplete = isComplete
        self.isIncomplete = isIncomplete
        self.createdAt = createdAt
    }

    /// The text the reader follows: prose only, paragraphs separated by a blank line so
    /// `ScriptIndex` segments them as separate paragraphs.
    var proseText: String {
        blocks.compactMap { block -> String? in
            if case .prose(let text) = block { return text }
            return nil
        }
        .joined(separator: "\n\n")
    }

    var codeBlocks: [String] {
        blocks.compactMap { block -> String? in
            if case .code(let code) = block { return code }
            return nil
        }
    }
}

struct FollowUp: Identifiable, Equatable, Sendable {
    enum Likelihood: String, Sendable {
        case likely, possible, lessLikely

        var label: String {
            switch self {
            case .likely: "Likely"
            case .possible: "Possible"
            case .lessLikely: "Less likely"
            }
        }

        /// Green, amber, grey. Red belongs to the recording mark and nothing else.
        var color: Color {
            switch self {
            case .likely: InterviewTheme.Color.likely
            case .possible: InterviewTheme.Color.possible
            case .lessLikely: InterviewTheme.Color.lessLikely
            }
        }
    }

    let id: UUID
    let likelihood: Likelihood
    let text: String

    init(id: UUID = UUID(), likelihood: Likelihood, text: String) {
        self.id = id
        self.likelihood = likelihood
        self.text = text
    }
}

/// A question the feed detected, with its answers.
struct InterviewQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var answers: [InterviewAnswer]
    var followUps: [FollowUp]
    /// Which version is on screen. Switching between versions is out of scope for this pass, so it
    /// is always the newest — but the older ones are kept, not overwritten.
    var selectedAnswerID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        answers: [InterviewAnswer] = [],
        followUps: [FollowUp] = [],
        selectedAnswerID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.answers = answers
        self.followUps = followUps
        self.selectedAnswerID = selectedAnswerID ?? answers.last?.id
    }

    var selectedAnswer: InterviewAnswer? {
        guard let selectedAnswerID else { return answers.last }
        return answers.first { $0.id == selectedAnswerID } ?? answers.last
    }

    var hasEarlierVersions: Bool { answers.count > 1 }
}

/// One line of the live transcript strip.
///
/// The `id` is the transcriber's own utterance identity, which is what makes a revision an **update
/// to a line** rather than a second copy of it: speech recognition rewrites what it heard several
/// times before settling, and the strip must show that happening in place.
struct TranscriptLine: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    /// Detected question lines are underlined in the primary colour and tap to select their page.
    var isDetectedQuestion: Bool
    /// Set once the question it announced has a page.
    var questionID: UUID?
    /// False while the transcriber may still revise this line. Finalized history is never rewritten.
    var isFinal: Bool
    /// How many times the recogniser has revised this utterance, from `ConversationLog`.
    ///
    /// Carried so a diagnostic can show that a partial and its finalized form are the *same* line at
    /// two revisions rather than two pieces of speech — the distinction that decides whether a
    /// sentence was sent once or twice.
    var revision: Int

    init(
        id: UUID = UUID(),
        text: String,
        isDetectedQuestion: Bool = false,
        questionID: UUID? = nil,
        isFinal: Bool = true,
        revision: Int = 0
    ) {
        self.id = id
        self.text = text
        self.isDetectedQuestion = isDetectedQuestion
        self.questionID = questionID
        self.isFinal = isFinal
        self.revision = revision
    }
}

/// An image attached to the context panel. **In memory only for this pass** — no persistence, no
/// SwiftData, gone when the screen closes.
struct ContextImage: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data

    init(id: UUID = UUID(), data: Data) {
        self.id = id
        self.data = data
    }
}

/// What the user typed and attached in the context panel. Kept when the panel collapses.
struct ContextState: Equatable, Sendable {
    static let imageLimit = 5

    var note: String = ""
    private(set) var images: [ContextImage] = []

    var isFull: Bool { images.count >= Self.imageLimit }
    var counterText: String { "\(images.count)/\(Self.imageLimit) images" }

    /// Adds an image if there is room. Returns whether it was added, so the caller can tell the
    /// difference between "added" and "silently dropped".
    @discardableResult
    mutating func addImage(_ image: ContextImage) -> Bool {
        guard !isFull else { return false }
        images.append(image)
        return true
    }

    mutating func removeImage(id: UUID) {
        images.removeAll { $0.id == id }
    }

    #if DEBUG
    /// Fills the panel with plainly-synthetic placeholder thumbnails, for the screenshot that has to
    /// show a full context panel. Reachable only from a debug build and only when the launch
    /// argument asks for it — never from ordinary use, and never with anyone's real photos.
    static func synthetic(imageCount: Int, note: String) -> ContextState {
        var state = ContextState()
        state.note = note
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.09, 0.10, 0.11), (1.0, 1.0, 1.0), (0.18, 0.42, 0.37), (0.11, 0.12, 0.13), (0.98, 0.98, 0.96)
        ]
        for index in 0..<min(imageCount, imageLimit) {
            let (red, green, blue) = palette[index % palette.count]
            let size = CGSize(width: 112, height: 112)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor(white: red > 0.5 ? 0.75 : 0.45, alpha: 1).setFill()
                for line in 0..<4 {
                    context.fill(CGRect(x: 14, y: 22 + line * 18, width: 84 - line * 13, height: 6))
                }
            }
            if let data = image.pngData() {
                state.addImage(ContextImage(data: data))
            }
        }
        return state
    }
    #endif
}

/// What the recording mark in the header is saying.
enum RecordingState: Equatable, Sendable {
    /// Red, softly glowing, slowly pulsing (unless Reduce Motion is on).
    case live
    /// Hollow and grey. The session is open; new speech is not being processed.
    case paused
    /// Nothing is listening, and the mark is hidden entirely.
    case off

    var accessibilityLabel: String? {
        switch self {
        case .live: "Listening"
        case .paused: "Listening paused"
        case .off: nil
        }
    }
}

/// Where the screen's content comes from. Demo is scripted; live needs a service this build has no
/// connection to.
enum InterviewMode: Equatable, Sendable {
    case demo
    case live
}
