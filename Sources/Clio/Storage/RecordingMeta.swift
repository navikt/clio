// RecordingMeta.swift
// Clio
//
// The per-recording metadata sidecar written as `meta.json` inside each
// recording's UUID folder. This is the source of truth for human-readable
// names, timestamps, processing state, and upload state — filesystem names
// are deliberately opaque.
//
// Schema reference: docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md (section "Metadata Sidecar Schema").
//
// Forward-compatibility: unknown JSON fields on decode are tolerated (standard
// Codable behaviour). `schemaVersion` is present from day one so future changes
// can migrate rather than break.

import Foundation

// MARK: - Enums

enum ArtifactStatus: String, Codable {
    case missing          // artifact expected but not present (e.g. orphan transcript)
    case pending          // work not yet started
    case processing       // work in progress
    case done             // artifact produced successfully
    case failed           // work terminated with an error
}

enum AnonymizationStatus: String, Codable {
    case none             // not attempted in ARM
    case draft            // researcher started, did not finish
    case done             // completed in ARM
    case failed           // attempted but errored
}

enum UploadStatus: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
}

// MARK: - Sub-objects

struct AudioMeta: Codable, Equatable {
    /// Always `audio.m4a` in the Phase 0 layout — kept explicit for forward compat.
    var filename: String
    var status: ArtifactStatus
    var sizeBytes: Int64?
    var sha256: String?

    init(
        filename: String = "audio.m4a",
        status: ArtifactStatus = .pending,
        sizeBytes: Int64? = nil,
        sha256: String? = nil
    ) {
        self.filename = filename
        self.status = status
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

struct TranscriptMeta: Codable, Equatable {
    var filename: String
    var status: ArtifactStatus
    /// Engine identifier, e.g. `"large"`, `"medium"`. Optional so migrated records
    /// don't have to invent a value.
    var engine: String?
    var completedAt: Date?
    /// When the researcher last edited the transcript in the transcript editor.
    /// `nil` if the transcript has never been edited (raw NB-Whisper output).
    var lastEditedAt: Date?
    /// Number of beams used during transcription (1 = raskest, 5 = best).
    var numBeams: Int?
    /// Wall-clock seconds navt.py spent transcribing.
    var processingTimeSeconds: Double?

    init(
        filename: String = "transcript.txt",
        status: ArtifactStatus = .pending,
        engine: String? = nil,
        completedAt: Date? = nil,
        lastEditedAt: Date? = nil,
        numBeams: Int? = nil,
        processingTimeSeconds: Double? = nil
    ) {
        self.filename = filename
        self.status = status
        self.engine = engine
        self.completedAt = completedAt
        self.lastEditedAt = lastEditedAt
        self.numBeams = numBeams
        self.processingTimeSeconds = processingTimeSeconds
    }
}

struct AnonymizationMeta: Codable, Equatable {
    var status: AnonymizationStatus
    var completedAt: Date?
    /// Filename of the anonymized transcript inside the recording folder.
    /// Present only when `status == .done` (or .draft if researcher saved
    /// mid-work). Always `transcript_anonymized.txt` in Phase 0 — kept
    /// explicit for forward compat.
    var filename: String?
    /// Redaction counts by category from the last successful anonymization
    /// run. Preserved from legacy `.metadata.json` migration and populated
    /// by future in-app anonymization runs.
    var stats: [String: Int]?
    /// Set when the researcher explicitly signs off that the transcript is
    /// fully de-identified. This is independent of `status` (which tracks
    /// whether the ARM anonymization tool has run). A researcher may have
    /// anonymized manually outside ARM; sign-off is always required before
    /// upload, regardless of whether the ARM tool was used.
    var researcherConfirmedAt: Date?

    init(
        status: AnonymizationStatus = .none,
        completedAt: Date? = nil,
        filename: String? = nil,
        stats: [String: Int]? = nil,
        researcherConfirmedAt: Date? = nil
    ) {
        self.status = status
        self.completedAt = completedAt
        self.filename = filename
        self.stats = stats
        self.researcherConfirmedAt = researcherConfirmedAt
    }
}

struct UploadMeta: Codable, Equatable {
    var status: UploadStatus
    var uploadedAt: Date?
    /// Graph API drive-item ID if known. Used by Phase 1 verification to
    /// confirm the remote copy exists.
    var graphItemId: String?
    /// Resumable upload session URL for large-file uploads. Persisted so an
    /// interrupted upload resumes on next launch rather than restarting.
    var sessionUrl: String?
    /// Human-readable filename used on Teams (e.g. "D01_20260414_audio.m4a").
    /// Set at upload time from the recording's `neutralCode` + date + artifact type.
    var remoteName: String?

    init(
        status: UploadStatus = .pending,
        uploadedAt: Date? = nil,
        graphItemId: String? = nil,
        sessionUrl: String? = nil,
        remoteName: String? = nil
    ) {
        self.status = status
        self.uploadedAt = uploadedAt
        self.graphItemId = graphItemId
        self.sessionUrl = sessionUrl
        self.remoteName = remoteName
    }
}

struct UploadState: Codable, Equatable {
    var audio: UploadMeta
    var transcript: UploadMeta
    /// The anonymized transcript is the primary Phase 1 upload artifact.
    /// Only present/relevant when `anonymization.status == .done`.
    var anonymizedTranscript: UploadMeta

    init(
        audio: UploadMeta = UploadMeta(),
        transcript: UploadMeta = UploadMeta(),
        anonymizedTranscript: UploadMeta = UploadMeta()
    ) {
        self.audio = audio
        self.transcript = transcript
        self.anonymizedTranscript = anonymizedTranscript
    }

    // Custom decoder so that existing meta.json files that predate
    // `anonymizedTranscript` (schema v1) decode without throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio = try c.decode(UploadMeta.self, forKey: .audio)
        transcript = try c.decode(UploadMeta.self, forKey: .transcript)
        anonymizedTranscript = try c.decodeIfPresent(UploadMeta.self, forKey: .anonymizedTranscript) ?? UploadMeta()
    }
}

// MARK: - MobileImportMeta

/// Provenance metadata written when a recording is imported from the Clio
/// Recorder iOS app via the Bonjour/USB transfer flow.
///
/// `nil` on all recordings created natively on Mac.
struct MobileImportMeta: Codable, Equatable {
    /// Human-readable name of the iOS device (from Bonjour service name).
    var iOSDeviceName: String
    /// Original filename on the iOS device (e.g. `2026-06-04_14-35-22.wav`).
    var originalFilename: String
    /// When Clio Mac imported this recording.
    var importedAt: Date
    /// Whether the WAV file contained a `RODE_DUAL_CHANNEL` marker in its
    /// metadata. When `true`, the transcription pipeline applies the
    /// split-channel diarization flow (spec § 9.4).
    var isDualChannel: Bool
    /// The iOS-side recording ID (opaque string from `GET /recordings`).
    var iOSRecordingId: String
}



/// Sidecar written as `<recording-folder>/meta.json`. Codable for atomic
/// read-modify-write via `RecordingStore.updateMeta`.
///
/// Field order follows the spec; keep `schemaVersion` first so a human
/// inspecting the JSON sees it immediately.
struct RecordingMeta: Codable, Equatable, Identifiable {

    /// Bumped when backwards-incompatible changes are made to this schema.
    /// Phase 0 ships with version 1.
    static let currentSchemaVersion: Int = 1

    var schemaVersion: Int
    var id: UUID
    var createdAt: Date
    /// Human-readable label shown in the UI. Defaults to an ISO date label
    /// on creation; researchers can rename later.
    var displayName: String
    var durationSeconds: Double?

    var audio: AudioMeta
    var transcript: TranscriptMeta
    var anonymization: AnonymizationMeta
    var upload: UploadState
    /// Last date an expiry warning audit event was emitted for this recording.
    /// Used to deduplicate warnings to one per calendar day.
    var lastWarningDate: Date?
    /// Neutral participant code for this recording (e.g. "D01", "T03").
    /// Set by the researcher before upload. Used to generate the Teams
    /// filename. Upload is blocked if this is nil or empty.
    var neutralCode: String?
    /// Set when this recording was imported from a Clio Recorder iOS device
    /// via the Bonjour/USB transfer flow. `nil` for recordings captured on Mac.
    var mobileImport: MobileImportMeta?

    // MARK: - Factory

    /// Freshly-minted metadata for a new recording.
    /// - Parameters:
    ///   - id: recording UUID (caller typically generates with `UUID()`)
    ///   - createdAt: creation timestamp (default: now)
    ///   - displayName: human-readable label (default: ISO date of `createdAt`)
    static func new(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        displayName: String? = nil
    ) -> RecordingMeta {
        RecordingMeta(
            schemaVersion: currentSchemaVersion,
            id: id,
            createdAt: createdAt,
            displayName: displayName ?? defaultDisplayName(for: createdAt),
            durationSeconds: nil,
            audio: AudioMeta(),
            transcript: TranscriptMeta(),
            anonymization: AnonymizationMeta(),
            upload: UploadState(),
            lastWarningDate: nil
        )
    }

    static func defaultDisplayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Recording \(formatter.string(from: date))"
    }

    // MARK: - Codable (explicit for forward-compat tolerance)

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case displayName
        case durationSeconds
        case audio
        case transcript
        case anonymization
        case upload
        case lastWarningDate
        case neutralCode
        case mobileImport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? RecordingMeta.defaultDisplayName(for: createdAt)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        audio = try c.decodeIfPresent(AudioMeta.self, forKey: .audio) ?? AudioMeta()
        transcript = try c.decodeIfPresent(TranscriptMeta.self, forKey: .transcript) ?? TranscriptMeta()
        anonymization = try c.decodeIfPresent(AnonymizationMeta.self, forKey: .anonymization)
            ?? AnonymizationMeta()
        upload = try c.decodeIfPresent(UploadState.self, forKey: .upload) ?? UploadState()
        lastWarningDate = try c.decodeIfPresent(Date.self, forKey: .lastWarningDate)
        neutralCode = try c.decodeIfPresent(String.self, forKey: .neutralCode)
        mobileImport = try c.decodeIfPresent(MobileImportMeta.self, forKey: .mobileImport)
    }

    init(
        schemaVersion: Int,
        id: UUID,
        createdAt: Date,
        displayName: String,
        durationSeconds: Double?,
        audio: AudioMeta,
        transcript: TranscriptMeta,
        anonymization: AnonymizationMeta,
        upload: UploadState,
        lastWarningDate: Date? = nil,
        neutralCode: String? = nil,
        mobileImport: MobileImportMeta? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.displayName = displayName
        self.durationSeconds = durationSeconds
        self.audio = audio
        self.transcript = transcript
        self.anonymization = anonymization
        self.upload = upload
        self.lastWarningDate = lastWarningDate
        self.neutralCode = neutralCode
        self.mobileImport = mobileImport
    }
}
