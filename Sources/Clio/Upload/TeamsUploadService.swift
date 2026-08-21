// TeamsUploadService.swift
// Clio
//
// Manages the upload of anonymized transcripts to Teams/SharePoint via the
// Microsoft Graph API.
//
// Responsibilities:
//   - Read anonymized transcript from RecordingStore
//   - Update sidecar upload state via RecordingStore.updateMeta()
//   - Emit audit events: uploadQueued, uploadCompleted, uploadFailed

import Foundation
import Combine

@MainActor
final class TeamsUploadService: ObservableObject {

    static let shared = TeamsUploadService()

    private init() {}

    // MARK: - Upload

    /// Starts upload of the anonymized transcript for `recording` to the
    /// configured Teams channel. Updates the recording's sidecar and emits
    /// audit events.
    ///
    /// - Parameters:
    ///   - recording: the recording whose anonymized transcript to upload
    ///   - channel: the destination Teams channel (must be fully configured)
    ///   - remoteName: filename to use on Teams (from `UploadGate.remoteName(...)`)
    func upload(recording: RecordingMeta, channel: TeamsChannelRef, remoteName: String) async {
        let recordingId = recording.id

        // Mark as uploading
        updateSidecar(recordingId: recordingId) { $0.upload.anonymizedTranscript.status = .uploading }
        AuditLogger.shared.logUploadQueued(recordingId: recordingId, remoteName: remoteName)

        do {
            let fileURL = anonymizedTranscriptURL(recording: recording)
            try await performGraphUpload(
                fileURL: fileURL,
                remoteName: remoteName,
                channel: channel
            )

            updateSidecar(recordingId: recordingId) { meta in
                meta.upload.anonymizedTranscript.status = .uploaded
                meta.upload.anonymizedTranscript.uploadedAt = Date()
                meta.upload.anonymizedTranscript.remoteName = remoteName
            }
            AuditLogger.shared.logUploadCompleted(recordingId: recordingId, remoteName: remoteName)

        } catch {
            updateSidecar(recordingId: recordingId) { meta in
                meta.upload.anonymizedTranscript.status = .failed
                meta.upload.anonymizedTranscript.remoteName = remoteName
            }
            AuditLogger.shared.logUploadFailed(
                recordingId: recordingId,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Graph API

    /// Uploads the anonymized transcript to the configured Teams channel's
    /// file library via Microsoft Graph.
    ///
    /// Order of operations:
    ///  1. Re-check the channel's cached age estimate — refuses to upload
    ///     to a channel confirmed to be less than 24 hours old (compliance
    ///     guard against uploading before backup-exclusion propagates).
    ///     An *unknown* age (nil `channelCreatedAt`) is intentionally NOT
    ///     blocked here — that's a soft warning surfaced at channel
    ///     configuration time (`TeamsSettingsView`), not an upload-time
    ///     hard stop, per the approved plan.
    ///  2. Requires the channel to have been fully configured (i.e.
    ///     `driveId`/`filesFolderItemId` already resolved via
    ///     `TeamsSettingsView` — uploads never resolve these on the fly).
    ///  3. `GraphAuthService.acquireTokenSilent()` — silent token
    ///     acquisition with interactive fallback (handled inside
    ///     `GraphClient`'s request plumbing on a 401).
    ///  4. Direct small-file `PUT` (anonymized transcripts are plain text,
    ///     always well under the 4 MB small-file ceiling).
    private func performGraphUpload(
        fileURL: URL,
        remoteName: String,
        channel: TeamsChannelRef
    ) async throws {
        _ = try GraphClient.assertChannelAgeOK(createdAt: channel.channelCreatedAt)

        guard let driveId = channel.driveId, let itemId = channel.filesFolderItemId else {
            throw TeamsUploadError.channelNotFullyConfigured
        }

        let fileData = try Data(contentsOf: fileURL)
        try await GraphClient.shared.uploadSmallFile(
            driveId: driveId, parentItemId: itemId, filename: remoteName, data: fileData)
    }

    // MARK: - Helpers

    private func anonymizedTranscriptURL(recording: RecordingMeta) -> URL {
        StorageLayout.recordingFolder(id: recording.id)
            .appendingPathComponent(recording.anonymization.filename ?? "transcript_anonymized.txt")
    }

    private func updateSidecar(recordingId: UUID, transform: @escaping (inout RecordingMeta) -> Void) {
        do {
            try RecordingStore.shared.updateMeta(id: recordingId, transform: transform)
        } catch {
            print("⚠️ TeamsUploadService: could not update sidecar for \(recordingId): \(error)")
        }
    }
}

/// Errors specific to the upload orchestration in `TeamsUploadService`,
/// as opposed to `GraphAuthError` (sign-in) or `GraphAPIError` (Graph
/// HTTP calls).
enum TeamsUploadError: LocalizedError {
    case channelNotFullyConfigured

    var errorDescription: String? {
        switch self {
        case .channelNotFullyConfigured:
            return """
            Teams-kanalen mangler informasjon om fil-plassering. Gå til \
            Innstillinger → Teams og lagre kanalen på nytt.
            """
        }
    }
}
