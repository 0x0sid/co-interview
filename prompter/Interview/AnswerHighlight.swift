import SwiftUI

/// Marks the characters of a `==highlight==` in an answer's attributed text. It survives slicing a
/// paragraph out of the aligned text and hiding inline-code backticks, so the marker lands on the
/// same characters whichever path built the text.
enum AnswerEmphasisKey: AttributedStringKey {
    typealias Value = Bool
    static let name = "neverblank.answerEmphasis"
}

/// The run-level tag the renderer looks for. It carries no styling of its own.
struct AnswerHighlightAttribute: TextAttribute {}

/// Draws a highlight as a highlighter band **behind** the glyphs.
///
/// **No reflow, by construction.** A `TextRenderer` draws an already laid-out `Text`; it cannot
/// change a glyph's font, weight, width or position. So a highlight that appears when its closing
/// `==` streams in changes pixels and nothing else — no moved line, no shifted token for
/// speech-following.
///
/// The band covers the line's typographic height with softly rounded ends, like a highlighter pen.
/// On a light band under light text (dark appearance) the highlighted glyphs are drawn
/// **colour-inverted**: light ink becomes near-black and spoken grey stays a distinct mid grey, so the
/// words stay readable and spoken words still look spoken. In Ultra Contrast (pure black and white)
/// a fill would erase white text, and an underline already means "spoken" there (`ScriptStyling`,
/// `underlineSpoken`), so the highlight is a thin white outline instead.
struct AnswerHighlightRenderer: TextRenderer {
    var color: Color
    /// Ultra Contrast: outline the phrase rather than fill behind it.
    var outline: Bool
    /// Dark appearance: draw highlighted glyphs inverted, dark on the light band.
    var invertsHighlightedText = false

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for band in bands(in: line) {
                if outline {
                    context.stroke(Path(roundedRect: band, cornerRadius: 3), with: .color(color), lineWidth: 1.25)
                } else {
                    context.fill(Path(roundedRect: band, cornerRadius: 3.5), with: .color(color))
                }
            }
            guard invertsHighlightedText, !outline else {
                context.draw(line)
                continue
            }
            for run in line {
                if run[AnswerHighlightAttribute.self] != nil {
                    var inverted = context
                    inverted.addFilter(.colorMatrix(Self.invert))
                    inverted.draw(run)
                } else {
                    context.draw(run)
                }
            }
        }
    }

    /// rgb → 1 − rgb, alpha kept.
    private static let invert: ColorMatrix = {
        var matrix = ColorMatrix()
        matrix.r1 = -1; matrix.r5 = 1
        matrix.g2 = -1; matrix.g5 = 1
        matrix.b3 = -1; matrix.b5 = 1
        return matrix
    }()

    /// One band per contiguous highlighted stretch of a line. A phrase is several runs when some of
    /// its words are already spoken (a different colour), and one merged band keeps it one stroke.
    private func bands(in line: Text.Layout.Line) -> [CGRect] {
        var spans: [(minX: CGFloat, maxX: CGFloat, baseline: CGFloat, ascent: CGFloat, descent: CGFloat)] = []
        for run in line where run[AnswerHighlightAttribute.self] != nil {
            let bounds = run.typographicBounds
            let rect = bounds.rect
            if let last = spans.last, rect.minX - last.maxX < 1.5 {
                spans[spans.count - 1].maxX = max(last.maxX, rect.maxX)
            } else {
                spans.append((rect.minX, rect.maxX, bounds.origin.y, bounds.ascent, bounds.descent))
            }
        }
        return spans.map { span in
            if outline {
                // Around the glyphs, clear of the spoken underline's position just below the baseline.
                let top = span.baseline - span.ascent * 0.92
                let bottom = span.baseline + span.descent * 0.9
                return CGRect(x: span.minX - 3, y: top, width: span.maxX - span.minX + 6, height: bottom - top)
            }
            // The whole glyph height: inverted glyphs must never cross the band's edge.
            let top = span.baseline - span.ascent * 0.96
            let bottom = span.baseline + span.descent
            return CGRect(x: span.minX - 2, y: top, width: span.maxX - span.minX + 4, height: bottom - top)
        }
    }
}

extension AnswerStructure {
    /// A `Text` from answer text whose anchors carry `AnswerEmphasisKey`: the marked stretches are
    /// tagged for `AnswerHighlightRenderer`, everything else is passed through untouched (reading
    /// colours, keyword weight, fonts).
    static func text(_ attributed: AttributedString) -> Text {
        var segments: [Text] = []
        for (marked, range) in attributed.runs[AnswerEmphasisKey.self] {
            let piece = Text(AttributedString(attributed[range]))
            segments.append(marked == true ? piece.customAttribute(AnswerHighlightAttribute()) : piece)
        }
        guard var result = segments.first else { return Text(attributed) }
        for segment in segments.dropFirst() {
            result = Text("\(result)\(segment)")
        }
        return result
    }

    /// Tags each range (UTF-16 offsets into `source`, the string `attributed` was built from).
    static func mark(_ attributed: inout AttributedString, ranges: [NSRange], in source: String) {
        for range in ranges {
            let start = String.Index(utf16Offset: range.location, in: source)
            let end = String.Index(utf16Offset: range.location + range.length, in: source)
            guard start <= end, end <= source.endIndex,
                  let target = Range(start..<end, in: attributed) else { continue }
            attributed[target][AnswerEmphasisKey.self] = true
        }
    }
}
