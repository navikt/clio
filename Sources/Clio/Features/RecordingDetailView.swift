import SwiftUI

// MARK: - Notification names

extension Notification.Name {
    /// Posted when a new transcription succeeds. `object` is the recording `UUID`.
    /// TranscriptEditorView listens to this and resets its anonymization state.
    static let armTranscriptionDidComplete = Notification.Name("ARMTranscriptionDidComplete")
}

// MARK: - Transcription UI state

private enum TranscriptionUIState {
    case notStarted
    case inProgress
    case completed(TranscriptionResult)
    case failed(TranscriptionError)
}

/// Display-ready summary of how a recording was captured, surfaced in the
/// detail panel's "Opptakskilde" section.
private struct RecordingSourceInfo {
    let sourceLabel: String
    let channelLabel: String
    let channelAssignment: String?
}

// MARK: - Recording Detail View
//
// Redesigned per RECORDING_DETAIL_VIEW.md (2026-04-17):
//   - Playback, transcription trigger, diarization placeholder, file info
//   - Anonymization, analysis, transcript modal, Finder — removed (moved to TranscriptEditorView)

struct RecordingDetailView: View {
    let recording: RecordingItem
    let onDismiss: () -> Void
    var onNavigateToTranscript: ((UUID) -> Void)?

    @ObservedObject var audioPlayer: AudioPlayer = .shared

    // Transcription state
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    @State private var transcriptionState: TranscriptionUIState = .notStarted
    @State private var transcriptionTask: Task<Void, Never>? = nil
    @AppStorage("transcription.defaultModel")    private var defaultModelRaw = TranscriptionModel.large.rawValue
    @AppStorage("transcription.verbatim")        private var verbatim = false
    @AppStorage("transcription.language")        private var language = "no"

    // Scrubber state
    @State private var scrubberProgress: Double = 0
    @State private var isDraggingScrubber = false
    @State private var scrubberTimer: Timer? = nil
    @State private var transcriptMeta: TranscriptMeta? = nil

    // Recording-source info (RØDE / channel layout) surfaced from the sidecar
    // (ClioMeta) or, as a fallback, the mobile-import metadata.
    @State private var sourceInfo: RecordingSourceInfo? = nil

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == recording.audioURL
    }

    private var displayedProgress: Double {
        if isDraggingScrubber { return scrubberProgress }
        return isCurrentFile ? audioPlayer.playbackProgress : 0
    }

    private var displayedCurrentTime: TimeInterval {
        displayedProgress * audioPlayer.duration
    }

    private var redAccent: Color {
        Color(red: 200 / 255, green: 16 / 255, blue: 46 / 255)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                playbackSection
                transcriptionSection
                fileInfoSection
                recordingSourceSection
                transcriptionDetailsSection
            }
            .padding(32)
        }
        .frame(width: 560)
        .onAppear {
            restoreTranscriptionState()
            loadTranscriptMeta()
            loadSourceInfo()
            startScrubberTimer()
        }
        .onDisappear {
            transcriptionTask?.cancel()
            scrubberTimer?.invalidate()
            scrubberTimer = nil
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(redAccent)

            Text(recording.filename)
                .font(.clioH2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Button {
                    if isCurrentFile {
                        audioPlayer.restart()
                    } else {
                        audioPlayer.play(url: recording.audioURL)
                    }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(redAccent)
                }
                .buttonStyle(.plain)
                .help("Start på nytt")

                Button {
                    let url = recording.audioURL
                    if isCurrentFile {
                        audioPlayer.togglePlayPause()
                    } else {
                        audioPlayer.play(url: url)
                    }
                } label: {
                    Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46, weight: .thin))
                        .foregroundStyle(redAccent)
                }
                .buttonStyle(.plain)
                .help(isCurrentFile && audioPlayer.isPlaying ? "Pause" : "Spill av")
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { displayedProgress },
                        set: { newValue in
                            scrubberProgress = newValue
                            isDraggingScrubber = true
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            if isCurrentFile {
                                audioPlayer.seek(to: scrubberProgress)
                            } else {
                                let url = recording.audioURL
                                audioPlayer.play(url: url)
                                audioPlayer.seek(to: scrubberProgress)
                            }
                            isDraggingScrubber = false
                        }
                    }
                )
                .accentColor(redAccent)

                HStack {
                    Text(formatTime(displayedCurrentTime))
                        .font(.clioMonoSmall)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(recording.formattedDuration)
                        .font(.clioMonoSmall)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(AppRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Transcription (4-state machine)

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkripsjon")
                .clioSectionLabel()

            VStack(alignment: .leading, spacing: 12) {
                switch transcriptionState {
                case .notStarted:
                    transcriptionNotStarted
                case .inProgress:
                    transcriptionInProgress
                case .completed(let result):
                    transcriptionCompleted(result: result)
                case .failed(let error):
                    transcriptionFailed(error: error)
                }
            }
            .padding(16)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private var transcriptionNotStarted: some View {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .large
        return VStack(alignment: .leading, spacing: 12) {
            Button(action: startTranscription) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.and.mic")
                    Text("Transkriber lydfil automatisk")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(redAccent)

            modelStatusRow(for: model)

            HStack(spacing: 16) {
                Label("Modell: \(model.displayName)", systemImage: "cpu")
            }
            .font(.clioLabel)
            .foregroundStyle(.secondary)

            if !transcriptionService.isInstalled {
                Label("no-transcribe er ikke installert. Åpne innstillinger for å installere.", systemImage: "exclamationmark.triangle")
                    .font(.clioLabel)
                    .foregroundStyle(AppColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var transcriptionInProgress: some View {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .large
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(transcriptionService.stage.displayName.isEmpty
                     ? "Forbereder..."
                     : transcriptionService.stage.displayName)
                    .font(.clioSubMedium)
                    .animation(.default, value: transcriptionService.stage.displayName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            modelStatusRow(for: model)

            if transcriptionService.progress > 0 {
                ProgressView(value: transcriptionService.progress)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.4), value: transcriptionService.progress)
            }

            Text("NB-Whisper-modellen lastes ved første kjøring – dette kan ta et minutt.")
                .font(.clioLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: cancelTranscription) {
                Text("Avbryt")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    private func transcriptionCompleted(result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text("Transkripsjon fullført")
                    .font(.clioSubMedium)
                    .foregroundStyle(AppColors.success)
            }

            HStack(spacing: 16) {
                Label("\(result.segments.count) segmenter", systemImage: "text.quote")
                Label("\(result.numSpeakers) taler\(result.numSpeakers == 1 ? "" : "e")", systemImage: "person.2")
                Label(formattedDuration(result.durationSeconds), systemImage: "clock")
            }
            .font(.clioCaption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    onNavigateToTranscript?(recording.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text("Åpne i transkripsjonseditoren")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(redAccent)

                Button(action: startTranscription) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Kjør på nytt")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func transcriptionFailed(error: TranscriptionError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                Text("Feil ved transkripsjon")
                    .font(.clioSubMedium)
                    .foregroundStyle(AppColors.destructive)
            }

            Text(error.errorDescription ?? "Ukjent feil")
                .font(.clioCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: startTranscription) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Prøv igjen")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Filinformasjon

    private var fileInfoSection: some View {        VStack(alignment: .leading, spacing: 12) {
            Text("Filinformasjon")
                .clioSectionLabel()

            VStack(spacing: 0) {
                infoRow(label: "Filnavn", value: recording.filename)
                Divider().background(Color.gray.opacity(0.2))
                infoRow(label: "Dato", value: recording.formattedDate)
                Divider().background(Color.gray.opacity(0.2))
                infoRow(label: "Varighet", value: recording.formattedDuration)
                Divider().background(Color.gray.opacity(0.2))
                infoRow(label: "Størrelse", value: recording.formattedSize)
            }
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Opptakskilde

    @ViewBuilder
    private var recordingSourceSection: some View {
        if let info = sourceInfo {
            VStack(alignment: .leading, spacing: 12) {
                Text("Opptakskilde")
                    .clioSectionLabel()

                VStack(spacing: 0) {
                    infoRow(label: "Kilde", value: info.sourceLabel)
                    Divider().background(Color.gray.opacity(0.2))
                    infoRow(label: "Kanaler", value: info.channelLabel)
                    if let assignment = info.channelAssignment {
                        Divider().background(Color.gray.opacity(0.2))
                        infoRow(label: "Kanalfordeling", value: assignment)
                    }
                }
                .background(Color.gray.opacity(0.04))
                .cornerRadius(AppRadius.large)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var transcriptionDetailsSection: some View {
        if let meta = transcriptMeta, meta.status == .done {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transkripsjonsdetaljer")
                    .clioSectionLabel()

                VStack(spacing: 0) {
                    if let engine = meta.engine {
                        infoRow(label: "Modell", value: modelDisplayName(engine))
                        Divider().background(Color.gray.opacity(0.2))
                    }
                    if let beams = meta.numBeams {
                        infoRow(label: "Nøyaktighet", value: beamsDisplayName(beams))
                        Divider().background(Color.gray.opacity(0.2))
                    }
                    if let secs = meta.processingTimeSeconds {
                        infoRow(label: "Transkripsjonstid", value: formattedProcessingTime(secs))
                    }
                    if let completedAt = meta.completedAt {
                        Divider().background(Color.gray.opacity(0.2))
                        infoRow(label: "Ferdigstilt", value: completedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .background(Color.gray.opacity(0.04))
                .cornerRadius(AppRadius.large)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    private func modelDisplayName(_ engine: String) -> String {
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
        if rem == 0 { return "\(m) min" }
        return "\(m) min \(rem) sek"
    }

    private func loadTranscriptMeta() {
        if let meta = try? RecordingStore.shared.load(id: recording.id) {
            transcriptMeta = meta.transcript
        }
    }

    /// Resolves how this recording was captured (RØDE stereo vs single channel)
    /// from the `.meta.json` sidecar written by Clio Recorder, falling back to
    /// the mobile-import metadata. Only sets `sourceInfo` when something is known.
    private func loadSourceInfo() {
        let storeMeta = try? RecordingStore.shared.load(id: recording.id)
        let mobile = storeMeta?.mobileImport
        let sidecar = ClioMeta.load(for: recording.audioURL)

        // Nothing to show unless we have at least one source of truth.
        guard sidecar != nil || mobile != nil else {
            sourceInfo = nil
            return
        }

        // Dual-channel if the sidecar says diarization isn't required, or the
        // mobile import was flagged dual-channel.
        let isDualChannel = sidecar.map { !$0.diarizationRequired } ?? (mobile?.isDualChannel ?? false)

        let sourceLabel: String
        switch sidecar?.recordingSource {
        case "ios_rode_wireless_micro":
            sourceLabel = "RØDE Wireless Micro"
        case "ios_builtin_mic":
            sourceLabel = "Innebygd mikrofon (mobil)"
        default:
            // No explicit source string — infer from the dual-channel flag.
            sourceLabel = isDualChannel ? "RØDE Wireless Micro" : "Mobilopptak"
        }

        let channelLabel = isDualChannel ? "2 (stereo)" : "1 (mono)"

        var assignment: String? = nil
        if isDualChannel {
            let left = (sidecar?.resolvedLeft ?? "INTERVJUER").capitalized
            let right = (sidecar?.resolvedRight ?? "INFORMANT").capitalized
            assignment = "Venstre: \(left) · Høyre: \(right)"
        }

        sourceInfo = RecordingSourceInfo(
            sourceLabel: sourceLabel,
            channelLabel: channelLabel,
            channelAssignment: assignment
        )
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.clioSub)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.clioSub)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func startScrubberTimer() {
        scrubberTimer?.invalidate()
        scrubberTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard !isDraggingScrubber else { return }
            _ = audioPlayer.playbackProgress
        }
    }

    private func restoreTranscriptionState() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recording.id.uuidString).json")
        if let data = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let result = try? decoder.decode(TranscriptionResult.self, from: data) {
                transcriptionState = .completed(result)
                return
            }
        }
        let txtURL = StorageLayout.transcriptURL(id: recording.id)
        if FileManager.default.fileExists(atPath: txtURL.path) {
            transcriptionState = .completed(TranscriptionResult(
                version: "1.0", model: "ukjent", language: "no",
                durationSeconds: 0, numSpeakers: 1,
                segments: [], metadata: TranscriptionResultMetadata(
                    inputFile: recording.path, processingTimeSeconds: 0,
                    modelVariant: "ukjent", computeType: "ukjent",
                    device: "ukjent", diarizationRun: nil
                )
            ))
        }
    }

    // MARK: - Transcription actions

    private func startTranscription() {
        guard transcriptionService.runtimeIsInstalled() else {
            transcriptionState = .failed(.notInstalled)
            return
        }

        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .large
        let audioURL = recording.audioURL

        transcriptionTask?.cancel()
        transcriptionState = .inProgress

        transcriptionTask = Task { @MainActor in
            do {
                try await TranscriptionService.shared.ensureModelAvailable(model, announce: true)
                guard !Task.isCancelled else { return }

                // A new transcription invalidates any previous anonymization result.
                // Clear storage once the run is visibly underway.
                clearAnonymizationData(for: recording.id)

                let result = try await TranscriptionService.shared.transcribe(
                    audioFile: audioURL,
                    speakers: 1,
                    model: model,
                    verbatim: verbatim,
                    language: language
                )
                guard !Task.isCancelled else { return }

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

                TranscriptionService.shared.saveTranscriptJSONPublic(result, recordingId: recording.id)

                AuditLogger.shared.log(.transcriptCompleted, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "engine": .string(model.rawValue),
                    "segmentCount": .int(result.segments.count),
                ])

                transcriptionState = .completed(result)
                loadTranscriptMeta()
                NotificationCenter.default.post(
                    name: .armTranscriptionDidComplete,
                    object: recording.id
                )
            } catch let error as TranscriptionError {
                guard !Task.isCancelled else { return }
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .failed
                }
                AuditLogger.shared.log(.transcriptFailed, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "error": .string(error.errorDescription ?? "unknown"),
                ])
                transcriptionState = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .failed
                }
                AuditLogger.shared.log(.transcriptFailed, payload: [
                    "recordingId": .string(recording.id.uuidString),
                    "error": .string(error.localizedDescription),
                ])
                transcriptionState = .failed(.processFailed(error.localizedDescription))
            }
        }
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        TranscriptionService.shared.cancel()
        transcriptionState = .notStarted
    }

    /// Clears all anonymization artefacts for a recording so that a fresh
    /// transcription starts with a clean anonymization slate.
    /// Affects: metadata sidecar, anonymized transcript text file, anonymization result JSON.
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

    @ViewBuilder
    private func modelStatusRow(for model: TranscriptionModel) -> some View {
        switch transcriptionService.modelDownloadState {
        case .downloading(let activeModel, let message) where activeModel == model:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("NB-Whisper \(model.displayName) lastes ned")
                    .font(.clioCaption)
                Text(message)
                    .font(.clioCaption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .ready(let readyModel) where readyModel == model:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text("NB-Whisper \(model.displayName) er lastet ned. Transkribering er nå mulig.")
                    .font(.clioCaption)
                Spacer()
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                Text(message)
                    .font(.clioCaption)
                Spacer()
            }
        default:
            if transcriptionService.modelIsCached(model) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                    Text("NB-Whisper \(model.displayName) er tilgjengelig lokalt.")
                        .font(.clioCaption)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(AppColors.accent)
                    Text("NB-Whisper \(model.displayName) er ikke lastet ned ennå. Den lastes ved behov.")
                        .font(.clioCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}
