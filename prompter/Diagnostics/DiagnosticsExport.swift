import Foundation

/// Turns traces into something a person can read and a machine can parse.
///
/// Two formats from one source: Markdown to read in the share sheet, JSON to diff or script. Both go
/// through `Redaction` on every free-text field, and neither ever contains image bytes.
///
/// **A report says whether it contains conversation.** The first line of the Markdown and a
/// top-level flag in the JSON say so, because the difference between "counts only" and "everything
/// that was said" decides who a file can be sent to.
@MainActor
enum DiagnosticsExport {
    // MARK: - Markdown

    static func markdown(session: GenerateDiagnostics, traces: [GenerateTrace], title: String) -> String {
        var out: [String] = []
        let hasContent = traces.contains { $0.captured != nil }

        out.append("# \(title)")
        out.append("")
        out.append(hasContent
            ? "> ⚠️ **This report contains captured conversation and answer text.** It includes what was said in the session and what the assistant wrote. Share it accordingly."
            : "> This report contains **no conversation text** — identities, counts, timings and outcomes only.")
        out.append("")
        out.append("- Session: `\(session.sessionID.uuidString)`")
        out.append("- Started: \(GenerateDiagnostics.stamp(session.startedAt))")
        out.append("- Content capture: **\(session.isContentCaptureEnabled ? "ON" : "OFF")**")
        out.append("- Traces in this report: \(traces.count)")
        if let failure = session.recorderFailure {
            out.append("- ⚠️ Recorder failure: \(Redaction.redact(failure))")
        }
        out.append("")

        for trace in traces {
            out.append(contentsOf: markdown(trace: trace))
        }

        if !session.sessionNotes.isEmpty {
            out.append("## Session notes")
            out.append("")
            for note in session.sessionNotes { out.append("- \(Redaction.redact(note))") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func markdown(trace: GenerateTrace) -> [String] {
        var out: [String] = []
        out.append("## Request `\(trace.requestID.uuidString.prefix(8))`")
        out.append("")
        if let problem = trace.problemNote {
            out.append("**🚩 Marked as a problem:** \(Redaction.redact(problem))")
            out.append("")
        }
        out.append("| | |")
        out.append("| --- | --- |")
        out.append("| Request id | `\(trace.requestID.uuidString)` |")
        out.append("| Session id | `\(trace.sessionID.uuidString)` |")
        out.append("| App | \(trace.appVersion) (\(trace.appBuild)) · commit `\(trace.commit)` |")
        out.append("| Backend | \(trace.backendVersion ?? "unknown") |")
        out.append("| Tapped | \(trace.tappedAt.map(GenerateDiagnostics.stamp) ?? "—") |")
        out.append("| Tap outcome | **\(trace.outcome.rawValue)**\(trace.outcomeReason.map { " — \($0)" } ?? "") |")
        out.append("| Interpreted title | \(trace.interpretedTitle ?? "(none yet)") |")
        out.append("| Stream | **\(trace.streamOutcome.rawValue)** |")
        if let status = trace.httpStatus { out.append("| HTTP | \(status) |") }
        if let detail = trace.failureDetail { out.append("| Error | \(Redaction.redact(detail)) |") }
        out.append("")

        out.append("**Transcript coverage**")
        out.append("")
        out.append("| | Lines | Characters |")
        out.append("| --- | --- | --- |")
        out.append("| Whole session transcript | \(trace.transcriptLineCount) | \(trace.transcriptCharacters) |")
        out.append("| Included in the request | \(trace.sentLineCount) | \(trace.sentCharacters) |")
        out.append("")
        out.append("- Historical context (background): \(trace.backgroundLineCount) line(s)")
        out.append("- New input being answered: \(trace.newInputLineCount) line(s)")
        out.append("- In-progress utterance included: \(trace.hasProvisionalLine ? "yes" : "no")")
        out.append("- Earlier suggestions sent: \(trace.priorSuggestionCount)")
        out.append("- Session note: \(trace.noteCharacters) character(s)")
        out.append("- Attachments: \(trace.preparedAttachmentCount) prepared of \(trace.attachmentCount)")
        out.append("- Omitted: \(trace.omitted ?? "nothing")")
        out.append("")

        if !trace.utterances.isEmpty {
            out.append("**Utterances at the tap**")
            out.append("")
            out.append("| id | rev | final | covered | chars |")
            out.append("| --- | --- | --- | --- | --- |")
            for utterance in trace.utterances {
                out.append("| `\(utterance.id.uuidString.prefix(8))` | \(utterance.revision) | \(utterance.isFinal ? "yes" : "no") | \(utterance.isCovered ? "yes" : "no") | \(utterance.characterCount) |")
            }
            out.append("")
        }

        out.append("**Route** — the actual model and provider as reported; never inferred from the request.")
        out.append("")
        if trace.attempts.isEmpty {
            out.append("- No attempt was reported.")
        } else {
            out.append("| # | gateway | requested | actual | serving provider | generation |")
            out.append("| --- | --- | --- | --- | --- | --- |")
            for attempt in trace.attempts {
                out.append("| \(attempt.number) | \(attempt.gateway) | `\(attempt.requestedModel)` | `\(attempt.actualModel)` | \(attempt.servingProvider) | \(attempt.generationID ?? "—") |")
            }
        }
        for failure in trace.attemptFailures { out.append("- Attempt failed: \(Redaction.redact(failure))") }
        if let version = trace.answerVersion { out.append("- Answer version: v\(version)") }
        out.append("")

        out.append("**Timings (ms)** — queued \(trace.queuedMs.map(String.init) ?? "—") · preparing \(trace.preparingMs.map(String.init) ?? "—") · to first text \(trace.toFirstTextMs.map(String.init) ?? "—") · to complete \(trace.toCompleteMs.map(String.init) ?? "—") · total \(trace.totalMs.map(String.init) ?? "—")")
        out.append("")

        if let captured = trace.captured {
            out.append("<details><summary>Captured content (conversation and answer text)</summary>")
            out.append("")
            out.append("*Raw transcript at the tap*")
            out.append("")
            for line in captured.transcriptAtTap { out.append("- \(Redaction.redact(line))") }
            out.append("")
            out.append("*The immutable snapshot*")
            out.append("")
            out.append("Background (historical context):")
            for line in captured.snapshotBackground { out.append("- \(Redaction.redact(line))") }
            out.append("")
            out.append("New input (what this request answers):")
            for line in captured.snapshotNewInput { out.append("- \(Redaction.redact(line))") }
            if let provisional = captured.snapshotProvisional {
                out.append("")
                out.append("Still being spoken: \(Redaction.redact(provisional))")
            }
            if !captured.priorSuggestions.isEmpty {
                out.append("")
                out.append("Earlier suggestions sent as context:")
                for suggestion in captured.priorSuggestions { out.append("- \(Redaction.redact(suggestion))") }
            }
            if !captured.note.isEmpty {
                out.append("")
                out.append("Session note: \(Redaction.redact(captured.note))")
            }
            if let json = captured.requestJSON {
                out.append("")
                out.append("*The serialized application request*")
                out.append("")
                out.append("```json")
                out.append(json)
                out.append("```")
            }
            if let messages = captured.providerMessages {
                out.append("")
                out.append("*The final provider messages, including system instructions*")
                out.append("")
                out.append("```")
                out.append(messages)
                out.append("```")
            }
            if let answer = captured.answerText {
                out.append("")
                out.append("*The answer*")
                out.append("")
                out.append("```")
                out.append(Redaction.redact(answer))
                out.append("```")
            }
            out.append("")
            out.append("</details>")
            out.append("")
        }
        return out
    }

    // MARK: - JSON

    static func json(session: GenerateDiagnostics, traces: [GenerateTrace]) -> String {
        var root: [String: Any] = [
            "schema": "co-interview.generate-diagnostics/1",
            "sessionID": session.sessionID.uuidString,
            "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
            "contentCaptureEnabled": session.isContentCaptureEnabled,
            "containsConversationText": traces.contains { $0.captured != nil },
            "traces": traces.map(dictionary(for:)),
            "sessionNotes": session.sessionNotes.map(Redaction.redact),
        ]
        if let failure = session.recorderFailure { root["recorderFailure"] = Redaction.redact(failure) }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"the diagnostics could not be encoded\"}"
        }
        return text
    }

    private static func dictionary(for trace: GenerateTrace) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = [
            "requestID": trace.requestID.uuidString,
            "sessionID": trace.sessionID.uuidString,
            "app": ["version": trace.appVersion, "build": trace.appBuild, "commit": trace.commit],
            "backendVersion": trace.backendVersion ?? "unknown",
            "tap": [
                "at": trace.tappedAt.map(iso.string(from:)) as Any? ?? NSNull(),
                "outcome": trace.outcome.rawValue,
                "reason": trace.outcomeReason as Any? ?? NSNull(),
            ] as [String: Any],
            "transcript": [
                "totalLines": trace.transcriptLineCount,
                "totalCharacters": trace.transcriptCharacters,
                "sentLines": trace.sentLineCount,
                "sentCharacters": trace.sentCharacters,
                "backgroundLines": trace.backgroundLineCount,
                "newInputLines": trace.newInputLineCount,
                "includesProvisional": trace.hasProvisionalLine,
                "priorSuggestions": trace.priorSuggestionCount,
                "noteCharacters": trace.noteCharacters,
                "omitted": trace.omitted as Any? ?? NSNull(),
            ] as [String: Any],
            "attachments": ["count": trace.attachmentCount, "prepared": trace.preparedAttachmentCount] as [String: Any],
            "utterances": trace.utterances.map { utterance in
                [
                    "id": utterance.id.uuidString,
                    "revision": utterance.revision,
                    "isFinal": utterance.isFinal,
                    "isCovered": utterance.isCovered,
                    "characters": utterance.characterCount,
                ] as [String: Any]
            },
            "attempts": trace.attempts.map { attempt in
                [
                    "number": attempt.number,
                    "gateway": attempt.gateway,
                    "requestedModel": attempt.requestedModel,
                    "actualModel": attempt.actualModel,
                    "servingProvider": attempt.servingProvider,
                    "generationID": attempt.generationID as Any? ?? NSNull(),
                ] as [String: Any]
            },
            "attemptFailures": trace.attemptFailures.map(Redaction.redact),
            "stream": trace.streamOutcome.rawValue,
            "interpretedTitle": trace.interpretedTitle as Any? ?? NSNull(),
            "answer": ["version": trace.answerVersion as Any? ?? NSNull(),
                       "characters": trace.answerCharacters] as [String: Any],
            "timingsMs": [
                "queued": trace.queuedMs as Any? ?? NSNull(),
                "preparing": trace.preparingMs as Any? ?? NSNull(),
                "toFirstText": trace.toFirstTextMs as Any? ?? NSNull(),
                "toComplete": trace.toCompleteMs as Any? ?? NSNull(),
                "total": trace.totalMs as Any? ?? NSNull(),
            ] as [String: Any],
        ]
        if let status = trace.httpStatus { out["httpStatus"] = status }
        if let detail = trace.failureDetail { out["error"] = Redaction.redact(detail) }
        if let problem = trace.problemNote {
            out["problem"] = ["note": Redaction.redact(problem),
                              "at": trace.markedAt.map(iso.string(from:)) as Any? ?? NSNull()] as [String: Any]
        }
        if let captured = trace.captured {
            out["captured"] = [
                "transcriptAtTap": captured.transcriptAtTap.map(Redaction.redact),
                "snapshotBackground": captured.snapshotBackground.map(Redaction.redact),
                "snapshotNewInput": captured.snapshotNewInput.map(Redaction.redact),
                "snapshotProvisional": captured.snapshotProvisional.map(Redaction.redact) as Any? ?? NSNull(),
                "priorSuggestions": captured.priorSuggestions.map(Redaction.redact),
                "note": Redaction.redact(captured.note),
                "requestJSON": captured.requestJSON as Any? ?? NSNull(),
                "providerMessages": captured.providerMessages as Any? ?? NSNull(),
                "answerText": captured.answerText.map(Redaction.redact) as Any? ?? NSNull(),
            ] as [String: Any]
        }
        return out
    }
}
