import AVFoundation
import Foundation
import SwiftUI

// MARK: - Folder Item Model
struct FolderItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var isExpanded: Bool = true
    var subfolders: [FolderItem] = []
    var recordings: [RecordingItem] = []
}

// MARK: - Folder Manager
class FolderManager: ObservableObject {
    @Published var folderStructure: [FolderItem] = []
    @Published var rootRecordings: [RecordingItem] = []
    private let baseURL: URL

    // File system monitoring
    private var fileDescriptors: [Int32] = []
    private var dispatchSources: [DispatchSourceFileSystemObject] = []
    private var reloadWorkItem: DispatchWorkItem?

    init(basePath: String) {
        self.baseURL = URL(fileURLWithPath: basePath)
        loadFolderStructure()
        startWatchingFolders()
    }

    deinit {
        stopWatchingFolders()
    }

    /// Start monitoring the base folder and all subfolders for changes
    private func startWatchingFolders() {
        // Watch the base folder
        watchFolder(at: baseURL.path)

        // Watch all subfolders
        let fileManager = FileManager.default
        if let items = try? fileManager.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for item in items {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    watchFolder(at: item.path)
                }
            }
        }
        print("👁️ Watching \(dispatchSources.count) folders for changes")
    }

    /// Watch a single folder for changes
    private func watchFolder(at path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("⚠️ Could not open folder for monitoring: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }

        source.setCancelHandler {
            close(fd)
        }

        fileDescriptors.append(fd)
        dispatchSources.append(source)
        source.resume()
    }

    /// Debounced reload to handle rapid file system changes
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            print("📁 Folder structure changed, reloading...")
            self?.loadFolderStructure()
            // Also reload the shared RecordingsManager
            RecordingsManager.shared.loadRecordings()
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// Stop monitoring all folders
    private func stopWatchingFolders() {
        for source in dispatchSources {
            source.cancel()
        }
        dispatchSources.removeAll()
        fileDescriptors.removeAll()
        reloadWorkItem?.cancel()
    }

    /// Refresh watchers when folder structure changes (e.g., new folder created)
    private func refreshWatchers() {
        stopWatchingFolders()
        startWatchingFolders()
    }

    func loadFolderStructure() {
        let fileManager = FileManager.default
        let previousFolderCount = folderStructure.count

        // Get all items in recordings folder
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else {
            return
        }

        var folders: [FolderItem] = []
        var newRootRecordings: [RecordingItem] = []

        for item in items {
            let isDirectory =
                (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory {
                let recordings = loadRecordingsInFolder(item)
                let folder = FolderItem(
                    name: item.lastPathComponent,
                    path: item.path,
                    recordings: recordings
                )
                folders.append(folder)
            } else if item.pathExtension == "m4a" || item.pathExtension == "mp3"
                || item.pathExtension == "wav"
            {
                if let recording = createRecordingItem(from: item) {
                    newRootRecordings.append(recording)
                }
            }
        }

        // Sort folders alphabetically
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Sort root recordings by date, newest first
        newRootRecordings.sort { $0.date > $1.date }

        // Update published properties
        folderStructure = folders
        rootRecordings = newRootRecordings

        print("📁 Loaded \(folders.count) folders, \(newRootRecordings.count) root recordings")

        // If folder count changed, refresh watchers to include new folders
        if folders.count != previousFolderCount {
            refreshWatchers()
        }
    }

    func loadRecordingsInFolder(_ folderURL: URL) -> [RecordingItem] {
        let fileManager = FileManager.default
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return []
        }

        return items.compactMap { item in
            if item.pathExtension == "m4a" || item.pathExtension == "mp3"
                || item.pathExtension == "wav"
            {
                return createRecordingItem(from: item)
            }
            return nil
        }
    }

    func createRecordingItem(from url: URL) -> RecordingItem? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = attrs[.size] as? Int64 ?? 0
        let date = attrs[.modificationDate] as? Date ?? Date()

        let audioFile = try? AVAudioFile(forReading: url)
        let audioDuration = audioFile.map {
            Double($0.length) / $0.processingFormat.sampleRate
        } ?? 0

        // Derive stable ID from the parent folder UUID (Phase 0 layout)
        // or generate a deterministic one from the path for legacy items.
        let stableId = StorageLayout.recordingId(from: url.deletingLastPathComponent())
            ?? UUID(uuidString: url.path.hash.description)
            ?? UUID()

        return RecordingItem(
            id: stableId,
            filename: url.lastPathComponent,
            path: url.path,
            date: date,
            size: size,
            duration: audioDuration.isNaN ? 0 : audioDuration
        )
    }

    func createFolder(name: String) {
        let folderURL = baseURL.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadFolderStructure()
    }

    func getTotalStorageUsed() -> String {
        let fileManager = FileManager.default
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: baseURL, includingPropertiesForKeys: [.fileSizeKey], options: [])
        else {
            return "0 MB"
        }

        var totalSize: Int64 = 0
        for item in items {
            if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        let mb = Double(totalSize) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Folder Tree View
struct FolderTreeView: View {
    let folderPath: String
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var folderManager: FolderManager
    @State private var isHovering = false
    @State private var isExpanded = false

    // Get the current folder data from folderManager (always up-to-date)
    private var folder: FolderItem? {
        folderManager.folderStructure.first { $0.path == folderPath }
    }

    var body: some View {
        if let folder = folder {
            VStack(spacing: 0) {
                // Folder row
                HStack(spacing: 8) {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)

                    Text(folder.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovering ? .white : .primary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isHovering ? Color.blue.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                }

                // Expanded recordings
                if isExpanded {
                    ForEach(folder.recordings) { recording in
                        HStack(spacing: 8) {
                            Spacer()
                                .frame(width: 28)  // Indent for nested items

                            RecordingRowView(
                                recording: recording,
                                isPlaying: audioPlayer.currentPlayingURL == recording.audioURL && audioPlayer.isPlaying,
                                audioPlayer: audioPlayer,
                                recordingsManager: recordingsManager
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - New Folder Dialog
struct NewFolderDialog: View {
    @Binding var folderName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Folder")
                .font(.system(size: 15, weight: .semibold))

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack(spacing: 12) {
                Button(AppCopy.Common.cancelEnglish) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(AppCopy.Common.create) {
                    onCreate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - Anonymization Reminder Dialog
struct AnonymizationReminderDialog: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.warning)

                Text("Before uploading")
                    .font(.system(size: 18, weight: .semibold))

                Text("Check that the text is anonymized")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Checklist
            VStack(alignment: .leading, spacing: 10) {
                ChecklistItem(text: "Remove names, contact info, and ID numbers")
                ChecklistItem(text: "Remove names of family, friends, and NAV employees")
                ChecklistItem(text: "Remove health information that could identify the participant")
                ChecklistItem(text: "Use codes like P1, P2, etc. instead of names")
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button(action: onContinue) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.doc.fill")
                        Text("Continue to Teams")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}

// Helper view for checklist items
struct ChecklistItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(AppColors.success)
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Recordings List Column (content column for 3-column split)

struct RecordingsListColumn: View {
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var audioPlayer: AudioPlayer
    @Binding var selectedRecording: RecordingItem?

    var body: some View {
        List(selection: $selectedRecording) {
            ForEach(recordingsManager.recordings) { recording in
                RecordingListRow(
                    recording: recording,
                    isPlaying: audioPlayer.currentPlayingURL == recording.audioURL && audioPlayer.isPlaying,
                    audioPlayer: audioPlayer,
                    recordingsManager: recordingsManager
                )
                .tag(recording)
                .listRowSeparator(.visible)
            }
        }
    }
}

// MARK: - Recording List Row

struct RecordingListRow: View {
    let recording: RecordingItem
    let isPlaying: Bool
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @State private var showDeleteConfirm = false
    @State private var isHovering = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.filename)
                    .font(.body)
                HStack(spacing: 4) {
                    Text(recording.formattedDate)
                    Text("·")
                    Text(recording.formattedDuration)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: isPlaying ? "waveform" : "waveform.circle")
                .font(.title3)
                .foregroundStyle(isPlaying ? .blue : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        }
        .listRowBackground(
            isHovering ? Color(nsColor: .controlAccentColor).opacity(0.1) : Color.clear
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button {
                let url = recording.audioURL
                if isPlaying {
                    audioPlayer.togglePlayPause()
                } else {
                    audioPlayer.play(url: url)
                }
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }

            Divider()

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(AppCopy.Common.delete, systemImage: "trash")
            }
        }
        .alert("Slett opptak?", isPresented: $showDeleteConfirm) {
            Button(AppCopy.Common.cancel, role: .cancel) {}
            Button(AppCopy.Common.delete, role: .destructive) {
                if isPlaying { audioPlayer.stop() }
                recordingsManager.deleteRecording(recording)
            }
        } message: {
            Text("Er du sikker på at du vil slette \(recording.filename)?")
        }
    }
}

// MARK: - Recording Player (Native)

struct RecordingPlayerNative: View {
    let recording: RecordingItem
    @ObservedObject var audioPlayer: AudioPlayer
    var onNavigateToTranscript: ((UUID) -> Void)?

    // Scrubber state
    @State private var isDraggingScrubber: Bool = false
    @State private var scrubberDragValue: Double = 0


    // Transcription
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    /// Shared in-flight tracker used by the Bibliotek pill. Observing
    /// here means the player reflects whichever surface kicked off the
    /// run — single source of truth, no double-press from two
    /// locations.
    @ObservedObject private var transcriptionRunner = TranscriptionRunner.shared
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var transcriptionResult: TranscriptionResult?
    @State private var transcriptionError: TranscriptionError?
    @State private var isTranscribing = false
    @AppStorage("transcription.defaultModel")    private var defaultModelRaw = TranscriptionModel.large.rawValue
    @AppStorage("transcription.verbatim")        private var verbatim = false
    @AppStorage("transcription.language")        private var language = "no"

    // Diarization (step 2)
    @State private var diarizationTask: Task<Void, Never>?
    @State private var isDiarizing = false
    @State private var diarizationError: String? = nil

    @State private var showSettings = false
    @State private var transcriptMeta: TranscriptMeta? = nil

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == recording.audioURL
    }

    /// True only for RØDE dual-channel recordings (ClioMeta sidecar or mobileImport flag).
    private var isDualChannelRecording: Bool {
        if let meta = ClioMeta.load(for: recording.audioURL), !meta.diarizationRequired {
            return true
        }
        if let recId = StorageLayout.recordingId(from: recording.audioURL.deletingLastPathComponent()),
           let recMeta = try? RecordingStore.shared.load(id: recId),
           recMeta.mobileImport?.isDualChannel == true {
            return true
        }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero section
                VStack(spacing: 32) {
                    Spacer().frame(height: 60)

                    ZStack {
                        Circle()
                            .fill(.blue.opacity(0.1))
                            .frame(width: 160, height: 160)
                        Image(systemName: "waveform")
                            .font(.system(size: 64, weight: .light))
                            .symbolEffect(.variableColor.iterative.reversing, isActive: isCurrentFile && audioPlayer.isPlaying)
                            .foregroundStyle(isCurrentFile && audioPlayer.isPlaying ? .blue : .secondary)
                    }

                    // Play/pause button
                    Button {
                        let url = recording.audioURL
                        if isCurrentFile {
                            audioPlayer.togglePlayPause()
                        } else {
                            audioPlayer.play(url: url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                            Text(isCurrentFile && audioPlayer.isPlaying ? "Pause" : "Spill av")
                                .font(.title3.weight(.semibold))
                        }
                        .frame(minWidth: 200)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if isCurrentFile {
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                Button {
                                    audioPlayer.restart()
                                } label: {
                                    Image(systemName: "backward.end.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Restart")

                                Slider(
                                    value: isDraggingScrubber
                                        ? $scrubberDragValue
                                        : Binding(
                                            get: { audioPlayer.playbackProgress },
                                            set: { _ in }
                                        ),
                                    in: 0...1,
                                    onEditingChanged: { dragging in
                                        if dragging {
                                            isDraggingScrubber = true
                                            scrubberDragValue = audioPlayer.playbackProgress
                                        } else {
                                            audioPlayer.seek(to: scrubberDragValue)
                                            isDraggingScrubber = false
                                        }
                                    }
                                )
                                .accentColor(Color(red: 200/255, green: 16/255, blue: 46/255))
                            }
                            .padding(.horizontal, 40)

                            HStack {
                                Text(formattedTime(
                                    (isDraggingScrubber ? scrubberDragValue : audioPlayer.playbackProgress)
                                    * audioPlayer.duration
                                ))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                Spacer()
                                Text(formattedTime(audioPlayer.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 40)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer().frame(height: 40)
                }
                .frame(maxWidth: .infinity)
                .padding()

                Divider().padding(.horizontal)

                Form {
                    transcriptionSection
                    if isDualChannelRecording {
                        diarizationSection
                    }

                    avidentifiseringBekreftSection
                    teamsUploadSection

                    Section("Fil informasjon") {
                        LabeledContent("Filnavn") {
                            Text(recording.filename)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent("Dato") { Text(recording.formattedDate) }
                        LabeledContent("Varighet") {
                            Text(recording.formattedDuration).font(.body.monospacedDigit())
                        }
                        LabeledContent("Størrelse") { Text(recording.formattedSize) }
                    }

                    if let meta = transcriptMeta, meta.status == .done {
                        Section("Transkripsjonsdetaljer") {
                            if let engine = meta.engine {
                                LabeledContent("Modell") { Text(transcriptionModelDisplayName(engine)) }
                            }
                            if let beams = meta.numBeams {
                                LabeledContent("Nøyaktighet") { Text(beamsDisplayName(beams)) }
                            }
                            if let secs = meta.processingTimeSeconds {
                                LabeledContent("Transkripsjonstid") { Text(formattedProcessingTime(secs)) }
                            }
                            if let completedAt = meta.completedAt {
                                LabeledContent("Ferdigstilt") {
                                    Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(recording.filename)
        .navigationSubtitle("\(recording.formattedDate) · \(recording.formattedDuration)")
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text(AppCopy.Common.settings)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(AppCopy.Common.close) { showSettings = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                ScrollView {
                    TranscriptionSettingsView()
                }
            }
            .frame(minWidth: 520, minHeight: 500)
        }
        .onAppear {
            restoreTranscriptionStateIfNeeded()
            transcriptMeta = loadMeta()?.transcript
        }
        .onChange(of: transcriptionRunner.inFlight) { _, newValue in
            // When the runner removes this recording (job finished or
            // was cancelled), refresh the local cache so the player
            // flips from "Transkriberer …" to the completed state.
            if !newValue.contains(recording.id) {
                transcriptionResult = nil
                restoreTranscriptionStateIfNeeded()
                transcriptMeta = loadMeta()?.transcript
            }
        }
        .onDisappear {
            // Cancel only local-state tasks (legacy path). Never cancel the
            // shared TranscriptionRunner — jobs must survive navigation.
            transcriptionTask?.cancel()
            diarizationTask?.cancel()
        }
    }

    // MARK: - Transcription state restoration

    private func loadMeta() -> RecordingMeta? {
        try? RecordingStore.shared.load(id: recording.id)
    }

    private func transcriptionModelDisplayName(_ engine: String) -> String {
        switch engine {
        case "tiny":   return "NB-Whisper Tiny"
        case "base":   return "NB-Whisper Base"
        case "small":  return "NB-Whisper Small"
        case "medium": return "NB-Whisper Medium"
        case "large":  return "NB-Whisper Large"
        default:       return engine
        }
    }

    private func beamsDisplayName(_ beams: Int) -> String {
        switch beams {
        case 1: return "Raskest (1)"
        case 2: return "Rask (2)"
        case 3: return "Middels (3)"
        case 4: return "Treg (4)"
        case 5: return "Svært treg (5)"
        default: return "\(beams)"
        }
    }

    private func formattedProcessingTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) sek" }
        let m = s / 60
        let rem = s % 60
        return rem == 0 ? "\(m) min" : "\(m) min \(rem) sek"
    }

    @ViewBuilder private var avidentifiseringBekreftSection: some View {
        let meta = loadMeta() ?? RecordingMeta(
            schemaVersion: RecordingMeta.currentSchemaVersion,
            id: recording.id,
            createdAt: recording.date,
            displayName: recording.filename,
            durationSeconds: recording.duration,
            audio: AudioMeta(filename: recording.filename, status: .done),
            transcript: TranscriptMeta(status: (TranscriptionCache.shared.hasResult(for: recording.path) || FileManager.default.fileExists(atPath: StorageLayout.transcriptURL(id: recording.id).path)) ? .done : .pending),
            anonymization: AnonymizationMeta(),
            upload: UploadState()
        )
        if meta.transcript.status == .done {
            Section("Avidentifisering") {
                AvidentifiseringBekreftSection(
                    recording: meta,
                    onMetaChanged: { updated in
                        try? RecordingStore.shared.updateMeta(id: updated.id) { m in
                            m.anonymization.researcherConfirmedAt = updated.anonymization.researcherConfirmedAt
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder private var teamsUploadSection: some View {
        let meta = loadMeta() ?? RecordingMeta(
            schemaVersion: RecordingMeta.currentSchemaVersion,
            id: recording.id,
            createdAt: recording.date,
            displayName: recording.filename,
            durationSeconds: recording.duration,
            audio: AudioMeta(filename: recording.filename, status: .done),
            transcript: TranscriptMeta(status: (TranscriptionCache.shared.hasResult(for: recording.path) || FileManager.default.fileExists(atPath: StorageLayout.transcriptURL(id: recording.id).path)) ? .done : .pending),
            anonymization: AnonymizationMeta(),
            upload: UploadState()
        )
        Section("Opplasting til Teams") {
            TeamsUploadSection(recording: meta)
        }
    }

    /// Restores a cached TranscriptionResult for this file (in-memory cache first,
    /// then JSON on disk, then transcript.txt in the recording's UUID folder).
    private func restoreTranscriptionStateIfNeeded() {
        guard transcriptionResult == nil, !isTranscribing else { return }

        // 1. In-memory cache hit (same app session)
        if let cached = TranscriptionCache.shared.result(for: recording.path) {
            transcriptionResult = cached
            return
        }

        // 2. JSON transcript fallback: check Application Support/AudioRecordingManager/transcripts/<uuid>.json
        //    This preserves speaker diarization labels across app restarts.
        //    Uses recording.id (stable UUID) instead of the audio filename stem
        //    (which is always "audio" in the Phase 0 layout and would collide).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recording.id.uuidString).json")
        if FileManager.default.fileExists(atPath: jsonURL.path),
           let jsonData = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let result = try? decoder.decode(TranscriptionResult.self, from: jsonData) {
                transcriptionResult = result
                TranscriptionCache.shared.store(result, for: recording.path)
                return
            }
        }

        // 3. Disk fallback: check transcript.txt in the recording's UUID folder
        let txtURL = StorageLayout.transcriptURL(id: recording.id)

        if FileManager.default.fileExists(atPath: txtURL.path),
           let text = try? String(contentsOf: txtURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Build a minimal TranscriptionResult from the plain-text so the UI
            // can show the "Ferdig" state and "Vis transkripsjon" button.
            let segment = TranscriptionSegment(
                id: 0,
                start: 0,
                end: 0,
                text: text,
                speaker: "SPEAKER_00",
                confidence: 1.0,
                words: []
            )
            let meta = TranscriptionResultMetadata(
                inputFile: recording.path,
                processingTimeSeconds: 0,
                modelVariant: "ukjent",
                computeType: "ukjent",
                device: "ukjent",
                diarizationRun: nil
            )
            let result = TranscriptionResult(
                version: "1.0",
                model: "ukjent",
                language: "no",
                durationSeconds: 0,
                numSpeakers: 1,
                segments: [segment],
                metadata: meta
            )
            transcriptionResult = result
            // Also populate the cache so future navigations skip disk I/O
            TranscriptionCache.shared.store(result, for: recording.path)
        }
    }

    // MARK: - Transcription section

    @ViewBuilder
    private var transcriptionSection: some View {
        Section("Transkripsjon") {
            let runnerInFlight = transcriptionRunner.inFlight.contains(recording.id)

            if runnerInFlight {
                TranscriptionProgressView(
                    stageName: transcriptionService.stage.displayName,
                    startTime: transcriptionRunner.startTimes[recording.id],
                    audioDuration: transcriptionRunner.audioDurations[recording.id],
                    model: defaultModelRaw,
                    numBeams: { let v = UserDefaults.standard.integer(forKey: "transcription.numBeams"); return v == 0 ? 3 : v }()
                )
                Button(AppCopy.Common.cancel, role: .destructive) {
                    transcriptionRunner.cancel(recordingId: recording.id)
                }
            } else if isTranscribing {
                // Local-state transcription path (back-compat; new clicks go through runner).
                TranscriptionProgressView(
                    stageName: transcriptionService.stage.displayName,
                    startTime: nil,
                    audioDuration: nil
                )
                Button(AppCopy.Common.cancel, role: .destructive, action: cancelTranscription)
            } else if let result = transcriptionResult {
                // Completed
                Label {
                    Text("Ferdig — \(result.segments.count) segmenter, \(result.numSpeakers) taler\(result.numSpeakers == 1 ? "" : "e")")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    onNavigateToTranscript?(recording.id)
                } label: {
                    Label(AppCopy.Labels.openInTranscriptEditor, systemImage: "doc.text")
                }
                Button {
                    transcriptionRunner.start(recordingId: recording.id, audioDuration: recording.duration)
                } label: {
                    Label(AppCopy.Labels.transcribeAgain, systemImage: "arrow.counterclockwise")
                }
                .disabled(transcriptionService.isBusy)
            } else if let error = transcriptionError {
                // Failed
                Label {
                    Text("Feil: \(error.errorDescription ?? "Ukjent feil")")
                        .foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button(AppCopy.Common.retry) {
                    transcriptionRunner.start(recordingId: recording.id, audioDuration: recording.duration)
                }
            } else {
                // Not started
                if transcriptionService.isInstalled {
                    Button {
                        transcriptionRunner.start(recordingId: recording.id, audioDuration: recording.duration)
                    } label: {
                        Label(AppCopy.Labels.transcribeWithNBWhisper, systemImage: "waveform.and.mic")
                    }
                    .disabled(transcriptionService.isBusy)
                    let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .large
                    if transcriptionService.isBusy {
                        Text("En transkripsjon kjører allerede – vennligst vent.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Modell: \(model.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if transcriptionService.isSettingUp {
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                        Text("Setter opp transkripsjon…")
                    }
                    let stageDesc = transcriptionService.setupStageDescription
                    Text(stageDesc.isEmpty
                         ? "Første gangs installasjon tar 5–15 min (torch ~2 GB)."
                         : stageDesc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let err = transcriptionService.setupError {
                    Label(AppCopy.Labels.setupFailed, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(AppCopy.Common.retry) {
                        Task { await TranscriptionService.shared.setupIfNeeded() }
                    }
                } else {
                    // setupIfNeeded() har ikke kjørt ennå (f.eks. første gang etter cold start)
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                        Text("Setter opp transkripsjon…")
                    }
                    Text("Starter oppsett. Vennligst vent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onAppear {
                            Task { await TranscriptionService.shared.setupIfNeeded() }
                        }
                }
            }
        }
    }

    // MARK: - Diarization section

    @ViewBuilder
    private var diarizationSection: some View {
        Section("Talerutskilling") {
            if isDiarizing {
                HStack(spacing: 10) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                    Text(transcriptionService.stage == .diarizing
                         ? "Identifiserer talere..."
                         : "Forbereder...")
                }
                if transcriptionService.diarizationProgress > 0 {
                    ProgressView(value: transcriptionService.diarizationProgress)
                        .animation(.easeInOut(duration: 0.4), value: transcriptionService.diarizationProgress)
                }
                Button(AppCopy.Common.cancel, role: .destructive) {
                    diarizationTask?.cancel()
                    TranscriptionService.shared.cancel()
                    isDiarizing = false
                }
            } else if let result = transcriptionResult, result.metadata.diarizationRun == true {
                // Completed
                Label {
                    Text("Talere identifisert")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    startDiarization()
                } label: {
                    Label(AppCopy.Labels.runAgain, systemImage: "arrow.counterclockwise")
                }
            } else if let error = diarizationError {
                Label {
                    Text(error).foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button(AppCopy.Common.retry, action: startDiarization)
            } else {
                // Not started
                if transcriptionResult != nil {
                    Button {
                        startDiarization()
                    } label: {
                        Label(AppCopy.Labels.identifySpeakers, systemImage: "person.2.fill")
                    }
                    .disabled(isTranscribing)
                    Text("FluidAudio (lokalt, Apple Neural Engine) · 2 talere")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Transkriber lydfilen først")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Actions

    private func startTranscription() {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .large
        let audioURL = recording.audioURL

        transcriptionTask?.cancel()
        transcriptionError = nil
        isTranscribing = true

        // A new transcription invalidates any previous anonymization.
        clearAnonymizationData(for: recording.id)

        transcriptionTask = Task { @MainActor in
            do {
                let result = try await TranscriptionService.shared.transcribe(
                    audioFile: audioURL,
                    speakers: 1,
                    model: model,
                    verbatim: verbatim,
                    language: language
                )
                guard !Task.isCancelled else { return }
                transcriptionResult = result
                isTranscribing = false

                // Store in the in-memory cache so the result survives file navigation
                TranscriptionCache.shared.store(result, for: recording.path)
                // Save full TranscriptionResult JSON to disk (preserves speaker labels across restarts)
                TranscriptionService.shared.saveTranscriptJSONPublic(result, recordingId: recording.id)
                ProcessingStateCache.shared.setStep(.transcription, status: .completed, for: recording.path)

                // Persist plain-text transcript into the recording's UUID folder
                let plainText = result.segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n\n")

                let transcriptURL = StorageLayout.transcriptURL(id: recording.id)
                try? plainText.write(to: transcriptURL, atomically: true, encoding: .utf8)
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .done
                    meta.transcript.completedAt = Date()
                    meta.transcript.engine = model.rawValue
                }

                AuditLogger.shared.log(.transcriptCompleted, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "engine": .string(model.rawValue),
                    "segmentCount": .int(result.segments.count),
                ])

                NotificationCenter.default.post(
                    name: .armTranscriptionDidComplete,
                    object: recording.id
                )
            } catch let error as TranscriptionError {
                guard !Task.isCancelled else { return }
                transcriptionError = error
                isTranscribing = false
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .failed
                }
                AuditLogger.shared.log(.transcriptFailed, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "error": .string(error.errorDescription ?? "unknown"),
                ])
            } catch {
                guard !Task.isCancelled else { return }
                transcriptionError = .processFailed(error.localizedDescription)
                isTranscribing = false
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .failed
                }
                AuditLogger.shared.log(.transcriptFailed, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            }
        }
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        TranscriptionService.shared.cancel()
        isTranscribing = false
    }

    private func clearAnonymizationData(for id: UUID) {
        _ = try? RecordingStore.shared.updateMeta(id: id) { meta in
            meta.anonymization = AnonymizationMeta()
        }
        let fm = FileManager.default
        try? fm.removeItem(at: StorageLayout.anonymizedTranscriptURL(id: id))
        try? fm.removeItem(at: StorageLayout.anonymizationResultURL(id: id))
        AuditLogger.shared.log(.anonymizationClearedOnRetranscription, payload: [
            "recordingId": .string(id.uuidString),
            "reason": .string("re-transcription"),
        ])
    }

    private func startDiarization() {
        guard let result = transcriptionResult else { return }
        isDiarizing = true
        diarizationError = nil
        diarizationTask = Task {
            do {
                let updated = try await TranscriptionService.shared.diarize(
                    audioFile: recording.audioURL,
                    existingResult: result,
                    speakers: 2
                )
                await MainActor.run {
                    transcriptionResult = updated
                    isDiarizing = false
                }
            } catch {
                await MainActor.run {
                    diarizationError = error.localizedDescription
                    isDiarizing = false
                }
            }
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}


// MARK: - Icon Button with Stable Hover
struct IconButton: View {
    let action: () -> Void
    let icon: String
    let color: Color

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: NSColor.controlColor))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(nsColor: NSColor.labelColor))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                DispatchQueue.main.async { NSCursor.pointingHand.set() }
            case .ended:
                DispatchQueue.main.async { NSCursor.arrow.set() }
            }
        }
    }
}

// MARK: - Recording Row View
struct RecordingRowView: View {
    let recording: RecordingItem
    let isPlaying: Bool
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @State private var showDeleteConfirm = false
    @State private var isHovering = false

    /// True when this recording has a transcription result — either in the session cache
    /// or as a saved transcript.txt in the recording's UUID folder.
    private var hasTranscription: Bool {
        if TranscriptionCache.shared.hasResult(for: recording.path) { return true }
        let txtURL = StorageLayout.transcriptURL(id: recording.id)
        return FileManager.default.fileExists(atPath: txtURL.path)
    }

    private var hasDiarization: Bool {
        ProcessingStateCache.shared.state(for: recording.path).diarization.status == .completed
    }

    private var expiryState: ExpiryWarningState {
        guard let meta = loadMeta() else { return .none }
        return RecordingExpiryManager.shared.warningState(for: meta)
    }

    private var isAudioUploaded: Bool {
        guard let meta = loadMeta() else { return false }
        return meta.upload.audio.status == .uploaded
    }

    private func loadMeta() -> RecordingMeta? {
        do { return try RecordingStore.shared.load(id: recording.id) }
        catch { return nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "waveform" : "waveform.circle")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.filename)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(contentColor)

                    HStack(spacing: 4) {
                        Text(recording.formattedDate)
                        Text("·")
                        Text(recording.formattedDuration)
                    }
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(subtleColor)
                }

                Spacer()

                HStack(spacing: 4) {
                    if hasTranscription {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(Color(red: 200/255, green: 16/255, blue: 46/255).opacity(0.8))
                            .help("Transkribert")
                    }
                    if hasDiarization {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue.opacity(0.7))
                            .help("Talere identifisert")
                    }
                }

                Text(recording.formattedSize)
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(subtleColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }

            if expiryState != .none {
                ExpiryWarningBanner(warningState: expiryState, isUploaded: isAudioUploaded)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider().background(Color.gray.opacity(0.25))
        }
        .onHover { isHovering = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active: DispatchQueue.main.async { NSCursor.pointingHand.set() }
            case .ended: DispatchQueue.main.async { NSCursor.arrow.set() }
            }
        }
        .alert("Slett opptak?", isPresented: $showDeleteConfirm) {
            Button(AppCopy.Common.cancel, role: .cancel) {}
            Button(AppCopy.Common.delete, role: .destructive) {
                if isPlaying { audioPlayer.stop() }
                recordingsManager.deleteRecording(recording)
            }
        } message: {
            Text("Er du sikker på at du vil slette \(recording.filename)?")
        }
        .contextMenu {
            Button(action: {
                let url = recording.audioURL
                if isPlaying {
                    audioPlayer.togglePlayPause()
                } else {
                    audioPlayer.play(url: url)
                }
            }) {
                Label(isPlaying ? "Pause" : "Spill av", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }

            Divider()

            Divider()

            Button(role: .destructive, action: { showDeleteConfirm = true }) {
                Label(AppCopy.Common.delete, systemImage: "trash")
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return AppColors.accent }
        if isHovering { return Color.gray.opacity(0.08) }
        return Color.clear
    }

    private var contentColor: Color { isSelected ? .white : .primary }
    private var subtleColor: Color { isSelected ? .white.opacity(0.75) : .secondary }
    private var iconColor: Color {
        if isSelected { return .white }
        return isPlaying ? AppColors.accent : AppColors.accent.opacity(0.7)
    }
}

// MARK: - Recording Player Panel (right panel for Lydopptak tab)

struct RecordingPlayerPanel: View {
    let recording: RecordingItem
    @ObservedObject var audioPlayer: AudioPlayer

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == recording.audioURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Spacer().frame(height: 20)

                // Icon
                Image(systemName: "waveform")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(isCurrentFile && audioPlayer.isPlaying ? AppColors.accent : .secondary.opacity(0.5))
                    .animation(.easeInOut(duration: 0.2), value: audioPlayer.isPlaying)

                // Play/pause button
                Button(action: {
                    let url = recording.audioURL
                    if isCurrentFile {
                        audioPlayer.togglePlayPause()
                    } else {
                        audioPlayer.play(url: url)
                    }
                }) {
                    Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72, weight: .thin))
                        .foregroundStyle(AppColors.accent)
                }
                .buttonStyle(.plain)

                // Progress bar (only when this recording is active)
                if isCurrentFile {
                    VStack(spacing: 6) {
                        ProgressView(value: audioPlayer.playbackProgress)
                            .tint(AppColors.accent)
                            .padding(.horizontal, 60)

                        HStack {
                            Text(formattedTime(audioPlayer.playbackProgress * audioPlayer.duration))
                            Spacer()
                            Text(recording.formattedDuration)
                        }
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 60)
                    }
                    .transition(.opacity)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(recording.filename)
        .navigationSubtitle("\(recording.formattedDate) · \(recording.formattedDuration) · \(recording.formattedSize)")
        .animation(.easeInOut(duration: 0.2), value: isCurrentFile)
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Bibliotek Screen

struct BibliotekScreen: View {
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var audioPlayer: AudioPlayer
    @Binding var selectedRecording: RecordingItem?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                BibliotekView(
                    recordingsManager: recordingsManager,
                    audioPlayer: audioPlayer,
                    selectedRecording: $selectedRecording,
                    isCompact: true
                )
                .frame(width: max(560, geo.size.width * 0.62))

                Divider()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let recording = selectedRecording {
            RecordingPlayerNative(
                recording: recording,
                audioPlayer: audioPlayer,
                onNavigateToTranscript: { id in
                    openWindow(id: "transcript-editor", value: id)
                }
            )
            .id(recording.path)
        } else {
            ContentUnavailableView(
                "Ingen opptak ennå",
                systemImage: "waveform",
                description: Text("Bruk «Ta opp lyd» for å starte ditt første opptak.")
            )
        }
    }
}
