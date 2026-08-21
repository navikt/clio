import Foundation

// MARK: - Legacy audit types (retained for existing anonymization call sites)

enum AuditOutcome: String, Codable {
    case success
    case error
}

private struct LegacyAuditEntry: Codable {
    let timestamp: Date
    let recordingId: String
    let action: String
    /// Redaction counts per category — never contains actual text.
    let stats: [String: Int]?
    let processingTimeMs: Double?
    let outcome: AuditOutcome
    /// Human-readable error description if outcome == .error. Never contains transcript text.
    let errorMessage: String?
}

// MARK: - Phase 0 event types

/// Typed audit events for the Phase 0 storage and Return Machine flows.
///
/// Every event carries `timestamp`, `eventType`, and a payload dictionary.
/// Payloads are flat `[String: AuditValue]` so new events and fields can be
/// added without rev'ing every existing entry. Do NOT put transcript content
/// or any free-form user text in here — counts and identifiers only.
struct AuditEvent: Codable {
    let timestamp: Date
    let actor: String       // e.g. NSUserName()
    let host: String        // Host.current().localizedName ?? ""
    let eventType: String
    let payload: [String: AuditValue]
}

/// Small sum type so we can encode heterogeneous payload values without
/// dragging in a schema library.
enum AuditValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int64(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported AuditValue type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .int64(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// Phase 0 event-type identifiers. Kept as a plain enum with `rawValue: String`
/// so unknown strings in a replayed log don't crash decoding.
///
/// Canonical event list (must match `FILE_MANAGEMENT_AND_TEAMS_SYNC.md` § Audit Log):
///   recordingCreated, recordingFinalized,
///   transcriptCompleted, transcriptFailed, transcriptEdited, transcriptAnonymized, transcriptAnalysed,
///   anonymizationStarted, anonymizationDiscarded,
///   complianceCheckConfirmed,
///   uploadQueued, uploadCompleted, uploadFailed,
///   recordingExpiryWarning, recordingExpired,
///   migrationCompleted
enum AuditEventType: String {
    case recordingCreated
    case recordingFinalized
    case transcriptCompleted
    case transcriptFailed
    case transcriptEdited
    case transcriptAnonymized
    case transcriptAnalysed
    case transcriptExported
    case anonymizationStarted
    case anonymizationDiscarded
    case anonymizationConfirmedByResearcher
    case anonymizationConfirmationRevoked
    case anonymizationClearedOnRetranscription
    case complianceCheckConfirmed
    case uploadQueued
    case uploadCompleted
    case uploadFailed
    case recordingExpiryWarning
    case recordingExpired
    case migrationCompleted
    case transcriptionStereoSplitStarted
    case transcriptionStereoSplitCompleted
    case transcriptionStereoSplitFailed

    // Legacy
    case anonymizationRun
}

// MARK: - Logger

/// Append-only JSONL audit log.
///
/// Phase 0: log lives at `~/Library/Application Support/AudioRecordingManager/audit/audit-YYYY-MM.jsonl`.
/// See ADR-1014 for rationale (user-editable Desktop dotfile was not tamper-resistant).
///
/// Each line is one JSON object (JSONL format). The log records:
///   - timestamps, recording IDs, redaction counts, event types — NEVER actual text content.
///
/// All writes are serialised through a private queue.
/// Use the typed convenience helpers (e.g. `logExpiryWarning`, `logExpired`, `logComplianceCheckConfirmed`)
/// in preference to the raw `log(_:payload:)` method wherever the payload shape is known.
class AuditLogger {
    static let shared = AuditLogger()

    private let encoder: JSONEncoder
    /// Serial queue ensures append operations are thread-safe.
    private let queue = DispatchQueue(
        label: "com.audiorecordingmanager.auditlogger",
        qos: .utility
    )

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Current month's log URL. Recomputed on each write so month rollover
    /// automatically opens a new file.
    private var currentLogURL: URL {
        StorageLayout.currentMonthAuditLog
    }

    // MARK: - Public API (legacy — existing call sites)

    /// Retained from the pre-Phase-0 logger so existing anonymization call
    /// sites in `RecordingDetailView.swift` and `TranscriptsView.swift` keep
    /// working unchanged. New code should use `log(_:payload:)` instead.
    func logAnonymization(
        recordingId: String,
        stats: [String: Int]?,
        processingTimeMs: Double,
        outcome: AuditOutcome,
        errorMessage: String? = nil
    ) {
        let entry = LegacyAuditEntry(
            timestamp: Date(),
            recordingId: recordingId,
            action: AuditEventType.anonymizationRun.rawValue,
            stats: stats,
            processingTimeMs: processingTimeMs,
            outcome: outcome,
            errorMessage: errorMessage
        )
        queue.async { [self] in
            appendLegacy(entry)
        }
    }

    // MARK: - Public API (Phase 0)

    /// Logs a Phase 0 typed event. The payload must contain no free-form
    /// user text — counts, IDs, status strings only.
    func log(_ type: AuditEventType, payload: [String: AuditValue] = [:]) {
        let event = AuditEvent(
            timestamp: Date(),
            actor: NSUserName(),
            host: Host.current().localizedName ?? "",
            eventType: type.rawValue,
            payload: payload
        )
        queue.async { [self] in
            appendEvent(event)
        }
    }

    // MARK: - Typed helpers (B5, B6)

    /// Emit when the researcher exports an anonymized transcript to a
    /// portable document (RTF today). `filenameHint` is the basename
    /// only — the full path is intentionally not logged because it can
    /// leak organisational structure or PII via folder names.
    func logTranscriptExported(
        recordingId: String,
        format: String,
        filenameHint: String
    ) {
        log(.transcriptExported, payload: [
            "recordingId": .string(recordingId),
            "format": .string(format),
            "filename": .string(filenameHint),
        ])
    }

    /// Emitted on each app launch for recordings in `.sevenDays` or `.oneDay` warning state.
    /// Deduplication (one per calendar day) is the caller's responsibility — see `RecordingExpiryManager`.
    func logExpiryWarning(recordingId: UUID, daysRemaining: Int) {
        log(.recordingExpiryWarning, payload: [
            "recordingId": .string(recordingId.uuidString),
            "daysRemaining": .int(daysRemaining)
        ])
    }

    /// Emitted immediately before `RecordingStore.delete()` is called for an expired recording.
    func logExpired(
        recordingId: UUID,
        createdAt: Date,
        deletedAt: Date,
        uploadStatus: String
    ) {
        log(.recordingExpired, payload: [
            "recordingId": .string(recordingId.uuidString),
            "createdAt": .string(ISO8601DateFormatter().string(from: createdAt)),
            "deletedAt": .string(ISO8601DateFormatter().string(from: deletedAt)),
            "uploadStatus": .string(uploadStatus)
        ])
    }

    /// Emitted when the researcher confirms the compliance checklist before
    /// the first upload (US-FM-15).
    func logComplianceCheckConfirmed() {
        log(.complianceCheckConfirmed)
    }

    /// Records that a researcher explicitly signed off that a transcript is
    /// fully de-identified. `armToolUsed` indicates whether the ARM built-in
    /// anonymization tool was also run (informational only — not a gate).
    func logAnonymizationConfirmedByResearcher(recordingId: UUID, armToolUsed: Bool) {
        log(.anonymizationConfirmedByResearcher, payload: [
            "recordingId": .string(recordingId.uuidString),
            "armToolUsed": .bool(armToolUsed)
        ])
    }

    func logAnonymizationConfirmationRevoked(recordingId: UUID) {
        log(.anonymizationConfirmationRevoked, payload: [
            "recordingId": .string(recordingId.uuidString)
        ])
    }

    func logUploadQueued(recordingId: UUID, remoteName: String) {
        log(.uploadQueued, payload: [
            "recordingId": .string(recordingId.uuidString),
            "remoteName": .string(remoteName)
        ])
    }

    func logUploadCompleted(recordingId: UUID, remoteName: String) {
        log(.uploadCompleted, payload: [
            "recordingId": .string(recordingId.uuidString),
            "remoteName": .string(remoteName)
        ])
    }

    func logUploadFailed(recordingId: UUID, reason: String) {
        log(.uploadFailed, payload: [
            "recordingId": .string(recordingId.uuidString),
            "reason": .string(reason)
        ])
    }

    // MARK: - Private

    private func ensureLogLocation() -> URL? {
        do {
            try StorageLayout.ensureDirectoriesExist()
        } catch {
            print("❌ AuditLogger: could not create audit directory: \(error)")
            return nil
        }
        return currentLogURL
    }

    private func appendLine(_ data: Data, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let fileHandle = try? FileHandle(forWritingTo: url) else {
                print("❌ AuditLogger: could not open log file for writing")
                return
            }
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            try? fileHandle.close()
        } else {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("❌ AuditLogger: could not create log file: \(error)")
            }
        }
    }

    private func appendLegacy(_ entry: LegacyAuditEntry) {
        guard let url = ensureLogLocation() else { return }
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8)
        else {
            print("❌ AuditLogger: failed to encode legacy entry")
            return
        }
        let logLine = (line + "\n").data(using: .utf8)!
        appendLine(logLine, to: url)
    }

    private func appendEvent(_ event: AuditEvent) {
        guard let url = ensureLogLocation() else { return }
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8)
        else {
            print("❌ AuditLogger: failed to encode event")
            return
        }
        let logLine = (line + "\n").data(using: .utf8)!
        appendLine(logLine, to: url)
    }
}
