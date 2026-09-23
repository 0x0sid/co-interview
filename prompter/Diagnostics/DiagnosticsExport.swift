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

    static func markdown(session: GenerateDiagnostics, traces: [GenerateTrace], title: String, decisions: String? = nil) -> String {
        var out: [String] = []
        let decisionRecords = decisionRecords(from: decisions)
        let hasContent = traces.contains { $0.captured != nil } || decisionRecords.contains { $0["content"] != nil }

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

        out.append(contentsOf: markdownDecisions(decisions, records: decisionRecords))

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
        out.append("| Decision | \(Redaction.redact(trace.decision ?? "not recorded")) |")
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

    // MARK: - Decision comparisons

    /// The records inside the backend's `/v1/copilot/diagnostics/decisions` payload.
    static func decisionRecords(from json: String?) -> [[String: Any]] {
        guard let data = json?.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return payload["records"] as? [[String: Any]] ?? []
    }

    /// One row per classification: what the existing detector decided, what Jev decided, and whether
    /// that comparison still meant anything by the time it finished. Jev's probabilities are in the
    /// JSON; this table is the readable summary.
    private static func markdownDecisions(_ json: String?, records: [[String: Any]]) -> [String] {
        var out = ["## Decision comparisons (shadow)", ""]
        guard let json, let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            out.append("Not available — decisions are off on the backend, the backend predates them, or it could not be reached.")
            out.append("")
            return out
        }
        if let config = payload["decisions"] as? [String: Any] {
            let mode = config["mode"] as? String ?? "?"
            let model = config["model"] as? String ?? "?"
            let version = config["config_version"] as? String ?? "?"
            out.append("Mode **\(mode)** · model `\(model)` · config `\(version)`. The existing detector controlled every verdict unless a row says otherwise.")
            out.append("")
        }
        guard !records.isEmpty else {
            out.append("No classifications recorded for this session.")
            out.append("")
            return out
        }
        out.append("| Snapshot | Utterances (rev) | Detector | Jev role (confidence) | Jev parent | Need | Agrees | Status | Jev ms | Tokens |")
        out.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for record in records {
            let baseline = record["baseline"] as? [String: Any] ?? [:]
            let jev = record["jev"] as? [String: Any] ?? [:]
            let comparison = record["comparison"] as? [String: Any]
            let snapshot = (record["snapshot_id"] as? String).map { String($0.prefix(8)) } ?? "—"
            let utterances = (record["utterances"] as? [[String: Any]] ?? []).map { u in
                "\((u["id"] as? String)?.prefix(4) ?? "?")@\(u["revision"] as? Int ?? 0)"
            }.joined(separator: " ")
            let role: String = {
                guard let role = jev["role"] as? String else { return "—" }
                if let confidence = jev["role_confidence"] as? Double { return "\(role) (\(String(format: "%.2f", confidence)))" }
                return role
            }()
            let parent = (jev["parent_id"] as? String).map { $0.count > 12 ? String($0.prefix(8)) : $0 } ?? "—"
            let agrees = (comparison?["role_agrees"] as? Bool).map { $0 ? "yes" : "**no**" } ?? "—"
            var status = jev["status"] as? String ?? "?"
            if let reason = record["stale_reason"] as? String { status += ": \(reason)" }
            if let failure = jev["failure"] as? [String: Any], let reason = failure["reason"] as? String { status += " (\(reason))" }
            if let controlled = record["controlled_by"] as? String, controlled != "baseline" { status += " · controlled by \(controlled)" }
            let latency = (jev["latency_ms"] as? Int).map(String.init) ?? "—"
            let tokens = ((jev["usage"] as? [String: Any])?["input_tokens"] as? Int).map(String.init) ?? "—"
            out.append("| `\(snapshot)` | \(utterances.isEmpty ? "—" : utterances) | \(baseline["kind"] as? String ?? "—") | \(role) | \(parent) | \(jev["answer_need"] as? String ?? "—") | \(agrees) | \(Redaction.redact(status)) | \(latency) | \(tokens) |")
        }
        out.append("")
        return out
    }

    // MARK: - JSON

    static func json(session: GenerateDiagnostics, traces: [GenerateTrace], decisions: String? = nil) -> String {
        let decisionRecords = decisionRecords(from: decisions)
        var root: [String: Any] = [
            "schema": "co-interview.generate-diagnostics/1",
            "sessionID": session.sessionID.uuidString,
            "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
            "contentCaptureEnabled": session.isContentCaptureEnabled,
            "containsConversationText": traces.contains { $0.captured != nil } || decisionRecords.contains { $0["content"] != nil },
            "traces": traces.map(dictionary(for:)),
            "sessionNotes": session.sessionNotes.map(Redaction.redact),
        ]
        // The backend's decision comparisons, as it sent them. Absent — not empty — when they could
        // not be fetched, so "not available" is never confused with "none recorded".
        if let decisions,
           let data = decisions.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            root["decisionComparisons"] = object
        }
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
            "decision": trace.decision as Any? ?? NSNull(),
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
