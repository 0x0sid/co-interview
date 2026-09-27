import Foundation

/// Whether the expanded Live transcript follows the newest speech, like a terminal: pinned to the
/// bottom while the reader is there, left alone once they scroll up, and pinned again when they tap
/// Latest or scroll back down.
///
/// Only **the reader's own scrolling** changes it — never new content arriving. Growth makes the view
/// momentarily "not at the bottom" until it is re-pinned, and treating that as the reader leaving
/// would switch following off on every new word.
struct TranscriptFollow: Equatable {
    private(set) var isFollowing = true
    private var isReaderScrolling = false

    /// The reader started dragging the transcript.
    mutating func readerBeganScrolling() { isReaderScrolling = true }

    /// A scroll came to rest. If the reader moved it, where it settled decides: at the bottom follows,
    /// anywhere above stays where they put it.
    mutating func scrollSettled(atBottom: Bool) {
        guard isReaderScrolling else { return }
        isReaderScrolling = false
        isFollowing = atBottom
    }

    /// New transcript arrived. Returns whether the view should move to the newest line.
    func shouldScrollForNewContent() -> Bool { isFollowing && !isReaderScrolling }

    /// "↓ Latest" is offered only while the reader is away from the bottom.
    var showsLatestButton: Bool { !isFollowing }

    /// Tapped "↓ Latest", or opened the transcript: back to the newest line, following.
    mutating func jumpToLatest() {
        isFollowing = true
        isReaderScrolling = false
    }
}
