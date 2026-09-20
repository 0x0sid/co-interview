#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

/// The diagnostics controls, inside the existing Debug surface.
///
/// Deliberately not on the interview screen: the approved interview interface is unchanged apart
/// from one "Mark a problem" item at the bottom of the ••• menu, which is the only thing a person
/// needs mid-interview. Everything else — switching capture on, exporting, clearing — belongs here.
struct DiagnosticsDebugSection: View {
    @State private var diagnostics = GenerateDiagnostics.shared
    @State private var share: SharePayload?

    var body: some View {
        Section("Generate diagnostics") {
            Toggle("Capture test content", isOn: Binding(
                get: { diagnostics.isContentCaptureEnabled },
                set: { diagnostics.isContentCaptureEnabled = $0 }
            ))
            Text("Off by default. When on, reports also include **what was said in the interview and the answers written for it** — the transcript, the exact snapshot, the request, the provider messages and the answer. Credentials and image data are never included. It returns to off at the start of every session.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            LabeledContent("Session", value: diagnostics.sessionID.uuidString.prefix(8).description)
            LabeledContent("Traces", value: "\(diagnostics.traces.count) of \(GenerateDiagnostics.maximumTraces)")
            LabeledContent("Captured text", value: diagnostics.hasCapturedContent ? "present" : "none")
            if let failure = diagnostics.recorderFailure {
                Text("Recorder failure: \(failure)").font(.footnote).foregroundStyle(.red)
            }

            Button("Export last request") {
                guard let trace = diagnostics.lastTrace else { return }
                share = payload(traces: [trace], title: "Co-Interview — last request")
            }
            .disabled(diagnostics.lastTrace == nil)

            Button("Export test session") {
                share = payload(traces: diagnostics.traces, title: "Co-Interview — test session")
            }
            .disabled(diagnostics.traces.isEmpty)

            Button("Clear diagnostics", role: .destructive) { diagnostics.clear() }
                .disabled(diagnostics.traces.isEmpty)
        }
        .sheet(item: $share) { payload in
            ShareSheet(items: payload.urls)
        }
    }

    /// Writes both formats to temporary files and hands them to the share sheet.
    ///
    /// Files rather than strings so the share sheet offers Files, Mail and AirDrop with real
    /// attachments. They live in the temporary directory, which the system reclaims; nothing is
    /// uploaded, and nothing leaves the phone unless the person picks a destination.
    private func payload(traces: [GenerateTrace], title: String) -> SharePayload {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = FileManager.default.temporaryDirectory
        let markdownURL = base.appendingPathComponent("co-interview-diagnostics-\(stamp).md")
        let jsonURL = base.appendingPathComponent("co-interview-diagnostics-\(stamp).json")
        let markdown = DiagnosticsExport.markdown(session: diagnostics, traces: traces, title: title)
        let json = DiagnosticsExport.json(session: diagnostics, traces: traces)
        // A failed export must not take the app with it: this is a diagnostic, not the interview.
        try? markdown.data(using: .utf8)?.write(to: markdownURL)
        try? json.data(using: .utf8)?.write(to: jsonURL)
        return SharePayload(urls: [markdownURL, jsonURL])
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
