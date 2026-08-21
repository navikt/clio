// TeamsChannelRef.swift
// Clio
//
// Teams destination for uploads. Clio does not have a "project" concept —
// there is exactly one configured Teams channel, set once in Settings, that
// every upload goes to.
//
// Stored as `AppState.teamsChannel` (persisted to `state/app.json`).

import Foundation

/// Identifies the private Teams channel uploads go to. The researcher or
/// IT provides these values in Settings. Clio never creates channels — it
/// only uploads to a channel that already exists.
struct TeamsChannelRef: Codable, Equatable {
    /// Teams team ID (GUID from M365 admin / Graph)
    var teamId: String
    /// Private channel ID within the team (GUID)
    var channelId: String

    /// When the channel was created in M365 (if known). Used for the
    /// 24-hour backup-exclusion propagation check. `nil` if unknown —
    /// Clio shows a soft warning rather than blocking (a freshly
    /// configured channel legitimately has no message history yet to
    /// derive an estimate from — see `GraphClient.estimateChannelCreatedDate`
    /// and `GraphClient.assertChannelAgeOK`).
    ///
    /// This is a best-effort heuristic, not an exact timestamp: direct
    /// channel metadata (which has a real `createdDateTime`) requires the
    /// `Channel.ReadBasic.All` Graph scope, which was not granted to this
    /// app. Instead this is derived by paging through the channel's
    /// messages (scope `ChannelMessage.Read.All`, which WAS granted) and
    /// taking the earliest `createdDateTime` seen.
    var channelCreatedAt: Date?

    /// Graph drive ID backing this channel's file library — resolved
    /// once via `GraphClient.resolveChannelFilesFolder` when the
    /// researcher configures this channel, and cached here so uploads
    /// never need to re-resolve it. `nil` until first configured.
    var driveId: String?

    /// The `driveItem` ID of the folder files should be uploaded into
    /// (the channel's "Files" tab root), resolved and cached alongside
    /// `driveId`.
    var filesFolderItemId: String?

    /// When this configuration was saved. Used for audit trail.
    var configuredAt: Date

    init(
        teamId: String = "",
        channelId: String = "",
        channelCreatedAt: Date? = nil,
        driveId: String? = nil,
        filesFolderItemId: String? = nil,
        configuredAt: Date = Date()
    ) {
        self.teamId = teamId
        self.channelId = channelId
        self.channelCreatedAt = channelCreatedAt
        self.driveId = driveId
        self.filesFolderItemId = filesFolderItemId
        self.configuredAt = configuredAt
    }

    /// True once the researcher has entered both IDs (i.e. there's
    /// something to resolve/upload to at all).
    var isConfigured: Bool {
        !teamId.isEmpty && !channelId.isEmpty
    }

    /// True when uploads can actually proceed — configured AND the
    /// one-time drive/folder resolution has completed.
    var isReadyForUpload: Bool {
        isConfigured && driveId != nil && filesFolderItemId != nil
    }
}
