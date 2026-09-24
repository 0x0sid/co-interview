import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The session's files: what is attached, what state each is in, what text was read from it — and
/// where to add more.
struct AttachmentsSheet: View {
    @Bindable var files: SessionFiles
    @Environment(\.dismiss) private var dismiss
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImportingFiles = false
    @State private var expandedPreviewID: UUID?

    /// Said once, above the list, in plain words.
    static let privacyNote = "Files are stored on this device. Relevant text may be sent to the AI service to answer your questions."
    static let imageNote = "Images are read on this device: only the text found in them can be used. The pictures themselves are not sent."

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.privacyNote)
                        .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                        .foregroundStyle(InterviewTheme.Color.ink)
                    Text(Self.imageNote)
                        .font(InterviewTheme.Font.ui(12.5, relativeTo: .footnote))
                        .foregroundStyle(InterviewTheme.Color.muted)
                }
                .listRowBackground(InterviewTheme.Color.surface)

                if let notice = files.notice {
                    Section {
                        HStack(alignment: .top) {
                            Text(notice)
                                .font(InterviewTheme.Font.ui(13, relativeTo: .footnote))
                                .foregroundStyle(InterviewTheme.Color.ink)
                            Spacer()
                            Button("Dismiss") { files.notice = nil }
                                .font(InterviewTheme.Font.ui(13, weight: .semibold, relativeTo: .footnote))
                        }
                    }
                    .listRowBackground(InterviewTheme.Color.surface)
                }

                Section {
                    if files.items.isEmpty {
                        Text("No files yet. Add a CV, notes, a job description or a screenshot.")
                            .font(InterviewTheme.Font.ui(14, relativeTo: .subheadline))
                            .foregroundStyle(InterviewTheme.Color.muted)
                    }
                    ForEach(files.items) { item in
                        row(item)
                            .swipeActions {
                                Button("Remove", role: .destructive) { files.remove(id: item.id) }
                            }
                    }
                } header: {
                    Text(files.countLabel ?? "Files")
                } footer: {
                    Text(AttachmentLimits.summary + " Supported: images and screenshots, PDF, text, Markdown, RTF and Word (.docx).")
                }
                .listRowBackground(InterviewTheme.Color.surface)
            }
            .scrollContentBackground(.hidden)
            .background(InterviewTheme.Color.background)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { addBar }
            .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                // Every type can be picked, so an unsupported one is listed and explained rather
                // than silently greyed out in the picker.
                if case .success(let urls) = result {
                    for url in urls { files.importFile(at: url) }
                }
            }
            .onChange(of: photoSelection) { _, items in
                Task { await importPhotos(items) }
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoSelection, maxSelectionCount: 10, matching: .images) {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Add from Photos")
            Button {
                isImportingFiles = true
            } label: {
                Label("Files", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Add from Files")
        }
        .font(InterviewTheme.Font.ui(15, weight: .semibold, relativeTo: .body))
        .buttonStyle(.bordered)
        .tint(InterviewTheme.Color.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(InterviewTheme.Color.background)
    }

    @ViewBuilder
    private func row(_ item: SessionFiles.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(InterviewTheme.Font.ui(15, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(InterviewTheme.Color.ink)
                        .lineLimit(2)
                    Text(item.summary)
                        .font(InterviewTheme.Font.ui(12, relativeTo: .caption1))
                        .foregroundStyle(InterviewTheme.Color.muted)
                    status(item)
                }
                Spacer(minLength: 0)
                if item.status.isWorking {
                    Button("Cancel") { files.cancel(id: item.id) }
                        .font(InterviewTheme.Font.ui(13, weight: .semibold, relativeTo: .footnote))
                        .buttonStyle(.borderless)
                } else {
                    Button {
                        files.remove(id: item.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(InterviewTheme.Color.muted)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(item.filename)")
                }
            }
            if let detail = item.detail {
                Text(detail)
                    .font(InterviewTheme.Font.ui(12.5, relativeTo: .footnote))
                    .foregroundStyle(item.status == .ready ? InterviewTheme.Color.muted : InterviewTheme.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview = item.preview {
                Button {
                    expandedPreviewID = expandedPreviewID == item.id ? nil : item.id
                } label: {
                    Text(preview)
                        .font(InterviewTheme.Font.ui(12.5, relativeTo: .footnote))
                        .foregroundStyle(InterviewTheme.Color.ink)
                        .lineLimit(expandedPreviewID == item.id ? nil : 3)
                        .multilineTextAlignment(.leading)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(InterviewTheme.Color.background, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Extracted text preview")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment-\(item.filename)")
    }

    @ViewBuilder
    private func status(_ item: SessionFiles.Item) -> some View {
        HStack(spacing: 6) {
            if item.status.isWorking {
                if item.status == .extracting, item.progress > 0 {
                    ProgressView(value: item.progress).frame(width: 60)
                    Text("\(item.status.label) \(Int(item.progress * 100))%")
                } else {
                    ProgressView().controlSize(.mini)
                    Text(item.status.label)
                }
            } else if item.status == .ready {
                Image(systemName: "checkmark.circle.fill")
                Text(item.chunkCount > 0 ? "Ready · \(item.chunkCount) excerpt\(item.chunkCount == 1 ? "" : "s")" : "Ready")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(item.status.label)
            }
        }
        .font(InterviewTheme.Font.ui(12, weight: .semibold, relativeTo: .caption1))
        .foregroundStyle(item.status == .ready ? InterviewTheme.Color.primary : InterviewTheme.Color.ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("attachment-status")
    }

    @ViewBuilder
    private func thumbnail(_ item: SessionFiles.Item) -> some View {
        Group {
            if let data = item.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(InterviewTheme.Color.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(InterviewTheme.Color.background)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(InterviewTheme.Color.hairline, lineWidth: 1))
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for (offset, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                files.notice = "A photo could not be loaded from the library."
                continue
            }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let stamp = Date.now.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            let name = "Photo \(stamp)\(items.count > 1 ? " \(offset + 1)" : "").\(type.preferredFilenameExtension ?? "jpg")"
            files.importData(data, filename: name, type: type)
        }
        photoSelection = []
    }
}

/// What an answer's request carried from the files, and which excerpts the model cited.
struct AnswerProvenanceSheet: View {
    let provenance: AnswerProvenance
    /// Files still attached, so a removed one is labelled rather than linked.
    let currentFileIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These excerpts from your files were included in the request for this answer. \"Cited\" means the model reported using that excerpt; included excerpts may not all have been used.")
                        .font(InterviewTheme.Font.ui(13, relativeTo: .footnote))
                        .foregroundStyle(InterviewTheme.Color.muted)
                }
                .listRowBackground(InterviewTheme.Color.surface)
                Section("Included in the request") {
                    ForEach(provenance.included) { excerpt in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(excerpt.filename)
                                    .font(InterviewTheme.Font.ui(14, weight: .semibold, relativeTo: .subheadline))
                                    .foregroundStyle(InterviewTheme.Color.ink)
                                Text(currentFileIDs.contains(excerpt.fileID) ? excerpt.locator : "\(excerpt.locator) · removed from this interview")
                                    .font(InterviewTheme.Font.ui(12, relativeTo: .caption1))
                                    .foregroundStyle(InterviewTheme.Color.muted)
                            }
                            Spacer()
                            Text(provenance.isCited(excerpt) ? "Cited" : "Included")
                                .font(InterviewTheme.Font.ui(11.5, weight: .semibold, relativeTo: .caption2))
                                .foregroundStyle(provenance.isCited(excerpt) ? InterviewTheme.Color.primary : InterviewTheme.Color.muted)
                        }
                    }
                }
                .listRowBackground(InterviewTheme.Color.surface)
            }
            .scrollContentBackground(.hidden)
            .background(InterviewTheme.Color.background)
            .navigationTitle("Context for this answer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
