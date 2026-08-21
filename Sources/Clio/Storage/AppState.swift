// AppState.swift
// Clio
//
// App-level state persisted as `state/app.json` inside the ARM data root.
// Holds the migration marker so the one-shot legacy-Desktop migration only
// runs once, plus the single configured Teams upload destination — Clio
// has no "project" concept, just one channel every upload goes to.
//
// Reads and writes go through atomic temp-file-then-rename to avoid corrupt
// state if the app is killed mid-write.

import Foundation

struct AppState: Codable, Equatable {
    /// Bumped when backwards-incompatible changes are made to this schema.
    static let currentSchemaVersion: Int = 1

    var schemaVersion: Int
    /// When the primary one-shot audio+transcript migration completed.
    /// `nil` means it has not run yet (or ran on a pre-Phase-0 build).
    /// The primary pass moves `.m4a` and `.txt` files and is separate from
    /// the legacy-metadata follow-up pass tracked by
    /// `legacyMetadataCleanedAt`.
    var migrationCompletedAt: Date?
    /// Number of recordings migrated on the one-shot pass. Useful for the
    /// post-migration confirmation message.
    var migrationRecordingCount: Int?
    /// When the follow-up pass that processes legacy `.metadata.json` files,
    /// non-`.m4a` Desktop audio, and cleans up the legacy audit log
    /// completed. `nil` means the follow-up has not run. This marker is
    /// **separate** from `migrationCompletedAt` so that users upgrading from
    /// the first-pass-only version still get their legacy metadata migrated
    /// on next launch without needing a manual reset.
    var legacyMetadataCleanedAt: Date?
    /// The single Teams channel every upload goes to. `nil` means it hasn't
    /// been configured yet — upload is blocked until it is.
    var teamsChannel: TeamsChannelRef?
    /// Global allowlist of strings that must NOT be redacted by the
    /// de-identification (avidentifisering) pipeline, even when the
    /// upstream NER model flags them. Case-insensitive, exact-match
    /// against the redacted span. Applied across every recording —
    /// e.g. "NAV", "Folketrygdloven", organisation names that are
    /// study-relevant context rather than personal data.
    ///
    /// Note: persisted with key `avidentExceptions` (Norwegian
    /// terminology — what we do is *de-identification*, not legally
    /// anonymisation, since the audio remains on disk and could in
    /// principle be re-linked).
    var avidentExceptions: [String]

    /// One-shot flag: when `false`, the next launch will seed
    /// `avidentExceptions` with the curated defaults from
    /// `DefaultAvidentExceptions.curated` (merged with anything the
    /// researcher already added). When `true`, the seed has already run
    /// and subsequent launches leave the list alone — so removing a
    /// default entry is persistent, not silently re-added.
    var hasSeededDefaultExceptions: Bool

    init(
        schemaVersion: Int = AppState.currentSchemaVersion,
        migrationCompletedAt: Date? = nil,
        migrationRecordingCount: Int? = nil,
        legacyMetadataCleanedAt: Date? = nil,
        teamsChannel: TeamsChannelRef? = nil,
        avidentExceptions: [String] = [],
        hasSeededDefaultExceptions: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.migrationCompletedAt = migrationCompletedAt
        self.migrationRecordingCount = migrationRecordingCount
        self.legacyMetadataCleanedAt = legacyMetadataCleanedAt
        self.teamsChannel = teamsChannel
        self.avidentExceptions = avidentExceptions
        self.hasSeededDefaultExceptions = hasSeededDefaultExceptions
    }

    // MARK: - Forward-compat Codable

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case migrationCompletedAt
        case migrationRecordingCount
        case legacyMetadataCleanedAt
        case teamsChannel
        case avidentExceptions
        case hasSeededDefaultExceptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        migrationCompletedAt = try c.decodeIfPresent(Date.self, forKey: .migrationCompletedAt)
        migrationRecordingCount = try c.decodeIfPresent(Int.self, forKey: .migrationRecordingCount)
        legacyMetadataCleanedAt = try c.decodeIfPresent(Date.self, forKey: .legacyMetadataCleanedAt)
        avidentExceptions = try c.decodeIfPresent([String].self, forKey: .avidentExceptions) ?? []
        hasSeededDefaultExceptions = try c.decodeIfPresent(
            Bool.self, forKey: .hasSeededDefaultExceptions) ?? false
        teamsChannel = try c.decodeIfPresent(TeamsChannelRef.self, forKey: .teamsChannel)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(migrationCompletedAt, forKey: .migrationCompletedAt)
        try c.encodeIfPresent(migrationRecordingCount, forKey: .migrationRecordingCount)
        try c.encodeIfPresent(legacyMetadataCleanedAt, forKey: .legacyMetadataCleanedAt)
        try c.encodeIfPresent(teamsChannel, forKey: .teamsChannel)
        try c.encode(avidentExceptions, forKey: .avidentExceptions)
        try c.encode(hasSeededDefaultExceptions, forKey: .hasSeededDefaultExceptions)
    }
}

// MARK: - Store

/// Persists `AppState` to `StorageLayout.appStateURL` with atomic writes and
/// safe defaults when the file is absent or corrupt.
enum AppStateStore {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Loads current state. Returns a fresh empty `AppState` if the file is
    /// missing or unreadable — callers should not treat a missing state file
    /// as an error.
    ///
    /// Side-effect: every load merges the curated `DefaultAvidentExceptions`
    /// into the persisted list. The merge is idempotent (case-insensitive
    /// dedupe) so user-added entries are preserved. A previously-removed
    /// default will reappear on next launch — by design, since the
    /// observed failure mode was the opposite (a corrupted empty list with
    /// the one-shot flag stuck at `true`, leaving recurring false
    /// positives like "ha"). If a researcher genuinely needs a default
    /// gone, the correct lever is to add a more specific span to the
    /// exception list rather than removing the broad default.
    ///
    /// `hasSeededDefaultExceptions` is kept on the model for back-compat
    /// with already-persisted JSON; the flag is set on every load but no
    /// longer gates the merge.
    static func load() -> AppState {
        let url = StorageLayout.appStateURL
        var state: AppState
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(AppState.self, from: data) {
            state = decoded
        } else {
            state = AppState()
        }

        let merged = DefaultAvidentExceptions.mergedWith(state.avidentExceptions)
        if merged != state.avidentExceptions || !state.hasSeededDefaultExceptions {
            state.avidentExceptions = merged
            state.hasSeededDefaultExceptions = true
            try? save(state)
        }
        return state
    }

    /// Atomically writes `state` to disk. Ensures the parent directory exists.
    /// Throws on any IO failure.
    static func save(_ state: AppState) throws {
        try StorageLayout.ensureDirectoriesExist()
        let data = try encoder.encode(state)
        try data.write(to: StorageLayout.appStateURL, options: .atomic)
    }

    /// Convenience: read, mutate, write. Callers pass a transform closure
    /// that receives an inout copy and may mutate any field.
    @discardableResult
    static func update(_ transform: (inout AppState) -> Void) throws -> AppState {
        var state = load()
        transform(&state)
        try save(state)
        return state
    }
}
