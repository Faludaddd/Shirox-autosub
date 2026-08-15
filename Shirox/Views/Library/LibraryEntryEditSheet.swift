import SwiftUI

struct LibraryEntryEditSheet: View {
    let entry: LibraryEntry?
    let media: Media
    let onSave: (MediaListStatus, Int, Double) -> Void
    var onDelete: (() -> Void)? = nil
    var scoreFormatOverride: ScoreFormat? = nil
    var progressUnit: String = "episode"
    /// Optional callback fired when the user toggles the "Mark as Private"
    /// switch in the edit sheet. When nil, the private toggle is hidden —
    /// this keeps the sheet backwards-compatible with call sites that don't
    /// support the flag.
    var onTogglePrivate: ((Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var local = LocalLibraryManager.shared
    @State private var status: MediaListStatus
    @State private var progress: Int
    @State private var score: Double
    @State private var isPrivate: Bool
    @State private var showDeleteConfirmation = false
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @StateObject private var editor = CollectionEditor()

    private var scoreFormat: ScoreFormat {
        if let scoreFormatOverride { return scoreFormatOverride }
        return media.provider == .anilist ? anilistAuth.scoreFormat : .point10
    }

    private func normalizeScoreIfNeeded() {
        guard score > 0, scoreFormat.maxScore < 100, score > scoreFormat.maxScore else { return }
        score = (score / 100.0) * scoreFormat.maxScore
    }

    init(entry: LibraryEntry?, media: Media,
         scoreFormatOverride: ScoreFormat? = nil,
         progressUnit: String = "episode",
         onSave: @escaping (MediaListStatus, Int, Double) -> Void,
         onDelete: (() -> Void)? = nil,
         onTogglePrivate: ((Bool) -> Void)? = nil) {
        self.entry = entry
        self.media = media
        self.onSave = onSave
        self.onDelete = onDelete
        self.scoreFormatOverride = scoreFormatOverride
        self.progressUnit = progressUnit
        self.onTogglePrivate = onTogglePrivate
        _status = State(initialValue: entry?.status ?? .planning)
        _progress = State(initialValue: entry?.progress ?? 0)
        _isPrivate = State(initialValue: entry?.isPrivate ?? false)
        // Local entries convert from their canonical score into the active format;
        // provider entries (override nil) fall back to their stored account score.
        _score = State(initialValue: entry?.displayScore(in: scoreFormatOverride ?? .point10) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Item 9: Merged Status + Progress + Score into one "Tracking" section
                Section("Tracking") {
                    Picker("Status", selection: $status) {
                        ForEach(MediaListStatus.allCases) { s in
                            Text(s.displayName(for: progressUnit == "chapter" ? .manga : .anime)).tag(s)
                        }
                    }
                    .pickerStyle(.menu)

                    if status != .completed {
                        #if !os(tvOS)
                        Stepper(
                            "\(progress) \(progressUnit)\(progress == 1 ? "" : "s") \(progressUnit == "chapter" ? "read" : "watched")",
                            value: $progress,
                            in: 0...(media.episodes ?? 9999)
                        )
                        #endif
                        if let total = media.episodes {
                            Text("of \(total) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ScoreInputView(score: $score, format: scoreFormat)
                }

                if onTogglePrivate != nil {
                    Section("Privacy") {
                        Toggle(isOn: $isPrivate) {
                            HStack {
                                Image(systemName: isPrivate ? "lock.fill" : "lock.open")
                                    .foregroundStyle(isPrivate ? .red : .secondary)
                                Text("Mark as Private")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .tint(Color.appAccent)
                        .glowEffect(isOn: isPrivate)
                        .onChange(of: isPrivate) { newValue in
                            onTogglePrivate?(newValue)
                        }
                    }
                }

                if scoreFormatOverride != nil {
                    Section("Collections") {
                        ForEach(local.collections) { collection in
                            Button {
                                let member = collection.mediaUniqueIds.contains(media.uniqueId)
                                local.setMembership(uniqueId: media.uniqueId, media: media,
                                                    inCollection: collection.id, member: !member)
                            } label: {
                                HStack {
                                    Text(collection.name).foregroundStyle(.primary)
                                    Spacer()
                                    if collection.mediaUniqueIds.contains(media.uniqueId) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            #if !os(tvOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    editor.requestDelete(collection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editor.beginRename(collection)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Color.appAccent)
                            }
                            #endif
                            .contextMenu {
                                Button {
                                    editor.beginRename(collection)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    editor.requestDelete(collection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        Button {
                            showNewCollection = true
                        } label: {
                            Label("New Collection", systemImage: "plus")
                        }
                    }
                }

                if entry != nil, onDelete != nil {
                    Section("Danger Zone") {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Remove from Library", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(entry == nil ? "Add to Library" : "Edit Entry")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let finalProgress = status == .completed ? (media.episodes ?? progress) : progress
                        onSave(status, finalProgress, score)
                        dismiss()
                    }
                }
            }
            .onAppear { normalizeScoreIfNeeded() }
            .onChangeOf(anilistAuth.scoreFormat) { normalizeScoreIfNeeded() }
            .onChangeOf(status) { newStatus in
                if newStatus == .completed, let total = media.episodes {
                    progress = total
                }
            }
            .alert("Remove from Library", isPresented: $showDeleteConfirmation) {
                Button("Remove", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \(media.title.displayTitle) from your library.")
            }
            .alert("New Collection", isPresented: $showNewCollection) {
                TextField("Name", text: $newCollectionName)
                Button("Create") {
                    let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newCollectionName = ""
                    guard !trimmed.isEmpty else { return }
                    let collection = local.createCollection(name: trimmed)
                    local.setMembership(uniqueId: media.uniqueId, media: media,
                                        inCollection: collection.id, member: true)
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            } message: {
                Text("Group this title under a custom collection.")
            }
            .collectionEditorAlerts(editor)
        }
    }
}
