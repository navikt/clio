import Combine
import Foundation
import SwiftUI

@MainActor
final class TranscriptionRunner: ObservableObject {
    static let shared = TranscriptionRunner()

    @Published private(set) var inFlight: Set<UUID> = []
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var startTimes: [UUID: Date] = [:]
    @Published private(set) var audioDurations: [UUID: Double] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var progressSubscription: AnyCancellable?

    private init() {}

    func start(recordingId: UUID, audioDuration: Double? = nil) {
        guard tasks[recordingId] == nil else { return }
        guard TranscriptionService.shared.runtimeIsInstalled() else {
            _ = try? RecordingStore.shared.updateMeta(id: recordingId) { meta in
                meta.transcript.status = .failed
            }
            AuditLogger.shared.log(.transcriptFailed, payload: [
                "recordingId": .string(recordingId.uuidString),
                "error": .string("no-transcribe mangler eller er ikke installert"),
            ])
            return
        }

        // Clear any prior anonymization data so the editor and library chips
        // immediately reflect the clean state before the new transcript lands.
        clearAnonymizationData(for: recordingId)

        let defaults = UserDefaults.standard
        let modelRaw = defaults.string(forKey: "transcription.defaultModel")
            ?? TranscriptionModel.large.rawValue
        let model = TranscriptionModel(rawValue: modelRaw) ?? .large
        let numBeams: Int = {
            let v = defaults.integer(forKey: "transcription.numBeams")
            return v == 0 ? 3 : v
        }()
        let verbatim = defaults.bool(forKey: "transcription.verbatim")
        let language = defaults.string(forKey: "transcription.language") ?? "no"

        inFlight.insert(recordingId)
        progress[recordingId] = 0
        startTimes[recordingId] = Date()
        if let d = audioDuration { audioDurations[recordingId] = d }

        // The service is a singleton with a single `activeProcess`; mirror
        // its published `progress` to this recording's slot while in-flight.
        progressSubscription?.cancel()
        progressSubscription = TranscriptionService.shared.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.progress[recordingId] = max(0, min(1, value))
            }

        let task = Task { @MainActor [weak self] in
            defer {
                self?.tasks[recordingId] = nil
                self?.inFlight.remove(recordingId)
                self?.progress[recordingId] = nil
                self?.startTimes[recordingId] = nil
                self?.audioDurations[recordingId] = nil
                self?.progressSubscription?.cancel()
                self?.progressSubscription = nil
            }

            let audioURL = StorageLayout.audioURL(id: recordingId)

            do {
                try await TranscriptionService.shared.ensureModelAvailable(model, announce: true)
                guard !Task.isCancelled else { return }

                // Reset old anonymization only once the run is visibly in-flight.
                clearAnonymizationData(for: recordingId)

                let result = try await TranscriptionService.shared.transcribe(
                    audioFile: audioURL,
                    speakers: 1,
                    model: model,
                    verbatim: verbatim,
                    language: language
                )
                guard !Task.isCancelled else { return }

                TranscriptionCache.shared.store(result, for: audioURL.path)
                TranscriptionService.shared.saveTranscriptJSONPublic(
                    result, recordingId: recordingId)
                ProcessingStateCache.shared.setStep(
                    .transcription, status: .completed, for: audioURL.path)

                let plainText = result.segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n\n")
                let transcriptURL = StorageLayout.transcriptURL(id: recordingId)
                try? plainText.write(to: transcriptURL, atomically: true, encoding: .utf8)
                _ = try? RecordingStore.shared.updateMeta(id: recordingId) { meta in
                    meta.transcript.status = .done
                    meta.transcript.completedAt = Date()
                    meta.transcript.engine = model.rawValue
                    meta.transcript.numBeams = numBeams
                    meta.transcript.processingTimeSeconds = result.metadata.processingTimeSeconds
                }

                AuditLogger.shared.log(.transcriptCompleted, payload: [
                    "recordingId": .string(recordingId.uuidString),
                    "engine": .string(model.rawValue),
                    "segmentCount": .int(result.segments.count),
                ])
            } catch {
                guard !Task.isCancelled else { return }
                _ = try? RecordingStore.shared.updateMeta(id: recordingId) { meta in
                    meta.transcript.status = .failed
                }
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                AuditLogger.shared.log(.transcriptFailed, payload: [
                    "recordingId": .string(recordingId.uuidString),
                    "error": .string(msg),
                ])
            }
        }
        tasks[recordingId] = task
    }

    func cancel(recordingId: UUID) {
        tasks[recordingId]?.cancel()
        // Swift Task cancellation doesn't propagate into the polling loop
        // inside TranscriptionService.transcribe(), so kill the subprocess
        // directly. The polling loop notices, transcribe() throws, and the
        // catch in start()'s Task body short-circuits via `Task.isCancelled`.
        TranscriptionService.shared.cancel()
        tasks[recordingId] = nil
        inFlight.remove(recordingId)
        progress[recordingId] = nil
        startTimes[recordingId] = nil
        audioDurations[recordingId] = nil
        progressSubscription?.cancel()
        progressSubscription = nil

        // Clear any prior `.failed` marker so the row offers "Transkriber"
        // (a clean restart) instead of "Prøv igjen" (which implies the run
        // errored on its own).
        _ = try? RecordingStore.shared.updateMeta(id: recordingId) { meta in
            if meta.transcript.status == .failed {
                meta.transcript.status = .pending
            }
        }
    }

    // MARK: - Anonymization reset

    /// Wipes all anonymization state for `id` — sidecar, anonymized transcript,
    /// and the raw anonymization-result JSON — so re-transcription always starts
    /// from a clean slate. The sidecar write posts `RecordingStore.didChangeNotification`,
    /// which triggers `TranscriptEditorView` and `BibliotekView` to refresh.
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
}
