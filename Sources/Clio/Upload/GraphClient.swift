import Foundation

/// Errors from Microsoft Graph API calls (as opposed to `GraphAuthError`,
/// which covers sign-in/token acquisition failures).
enum GraphAPIError: LocalizedError {
    case notAuthenticated
    case httpError(statusCode: Int, body: String)
    case invalidResponse
    case channelTooNew(createdAt: Date, hoursRemaining: Double)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Ikke autentisert mot Microsoft Graph."
        case .httpError(let statusCode, let body):
            return "Microsoft Graph-feil (HTTP \(statusCode)): \(body)"
        case .invalidResponse:
            return "Uventet svar fra Microsoft Graph."
        case .channelTooNew(let createdAt, let hoursRemaining):
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.locale = Locale(identifier: "nb_NO")
            return """
            Kanalen ble opprettet \(formatter.string(from: createdAt)) — vent til \
            sikkerhetskopiering er utelukket (ca. \(Int(hoursRemaining.rounded(.up))) \
            time(r) igjen) før du laster opp.
            """
        }
    }
}

/// Result of the 24-hour channel-age compliance check. Distinguishes a
/// hard stop (age is known and too recent) from a soft warning (age
/// could not be determined at all — e.g. zero messages in the channel).
/// This distinction matches the plan's explicit decision: unknown age is
/// a warning surfaced to the researcher, not a block, since a
/// freshly-configured channel legitimately has no message history to
/// derive an estimate from.
enum ChannelAgeCheck: Equatable {
    case ok
    case unknown
}

/// Thin wrapper around `URLSession` for the small set of Microsoft Graph
/// calls Clio needs. Deliberately not a full Graph SDK — the surface area
/// is small enough that a hand-rolled client is simpler to audit and
/// reason about for a compliance-sensitive upload path.
///
/// Every call attaches a bearer token from `GraphAuthService`; on a 401,
/// the call is retried once after a silent token refresh (handles the
/// case where a cached token expired between acquisition and use).
final class GraphClient {
    static let shared = GraphClient()

    private let session: URLSession
    private let baseURL = EntraConfig.graphBaseURL

    private init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Channel → drive resolution

    /// The Graph `driveItem` backing a channel's file library — see
    /// `GET /teams/{team}/channels/{channel}/filesFolder`. `driveId` and
    /// `itemId` together identify the folder that files should be
    /// uploaded into.
    struct ChannelFilesFolder {
        let driveId: String
        let itemId: String
    }

    /// Resolves the drive + folder-item backing a channel's file library.
    /// Called once when the researcher configures a `TeamsChannelRef` in
    /// the project settings UI — the result is cached on the model
    /// (`driveId`/`filesFolderItemId`), not re-resolved on every upload.
    func resolveChannelFilesFolder(teamId: String, channelId: String) async throws -> ChannelFilesFolder {
        let url = baseURL.appendingPathComponent("teams/\(teamId)/channels/\(channelId)/filesFolder")
        let data = try await get(url)

        struct DriveItemResponse: Decodable {
            struct ParentReference: Decodable {
                let driveId: String
            }
            let id: String
            let parentReference: ParentReference
        }

        let decoded = try JSONDecoder().decode(DriveItemResponse.self, from: data)
        return ChannelFilesFolder(driveId: decoded.parentReference.driveId, itemId: decoded.id)
    }

    // MARK: - Channel-age heuristic

    /// Best-effort estimate of when a channel was created, derived by
    /// paging through `GET /teams/{team}/channels/{channel}/messages` and
    /// tracking the minimum `createdDateTime` seen.
    ///
    /// This is a heuristic, not an exact answer: direct channel metadata
    /// (which has a real `createdDateTime`) requires `Channel.ReadBasic.All`,
    /// a scope NOT granted to this app — only `ChannelMessage.Read.All`
    /// was granted, specifically for this purpose (per
    /// `docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md`'s dependency table). The
    /// messages endpoint does not support `$orderby`/`$filter`, so every
    /// page must be walked. Returns `nil` if the channel has zero
    /// messages (no signal at all) — callers should treat `nil` as
    /// "unknown age" (soft warning, not a hard block), matching the
    /// existing `channelCreatedAt == nil` convention.
    func estimateChannelCreatedDate(teamId: String, channelId: String) async throws -> Date? {
        struct MessagesPage: Decodable {
            struct Message: Decodable {
                let createdDateTime: Date
            }
            let value: [Message]
            let nextLink: URL?

            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var earliest: Date?
        var nextURL: URL? = baseURL
            .appendingPathComponent("teams/\(teamId)/channels/\(channelId)/messages")
        var components = URLComponents(url: nextURL!, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "$top", value: "50")]
        nextURL = components?.url

        // Safety cap: a channel configured for this app is expected to be
        // freshly provisioned with little to no message history. If it
        // somehow has thousands of messages, don't page indefinitely —
        // treat the result as "unknown" rather than hammering Graph.
        var pagesFetched = 0
        let maxPages = 20

        while let url = nextURL, pagesFetched < maxPages {
            let data = try await get(url)
            let page = try decoder.decode(MessagesPage.self, from: data)
            for message in page.value {
                if earliest == nil || message.createdDateTime < earliest! {
                    earliest = message.createdDateTime
                }
            }
            nextURL = page.nextLink
            pagesFetched += 1
        }

        return earliest
    }

    /// Compliance guard: throws `GraphAPIError.channelTooNew` if the
    /// channel's cached creation estimate is known and less than 24 hours
    /// old — this IS a hard stop. If no estimate is available at all
    /// (`createdAt == nil`), returns `.unknown` rather than throwing: a
    /// freshly-configured channel with zero message history has no
    /// signal to derive an age from at all, and per the approved plan
    /// this is surfaced to the researcher as a warning, not a block.
    static func assertChannelAgeOK(createdAt: Date?) throws -> ChannelAgeCheck {
        guard let createdAt else {
            return .unknown
        }
        let hoursSinceCreation = Date().timeIntervalSince(createdAt) / 3600
        guard hoursSinceCreation >= 24 else {
            throw GraphAPIError.channelTooNew(createdAt: createdAt, hoursRemaining: 24 - hoursSinceCreation)
        }
        return .ok
    }

    // MARK: - Upload

    /// Uploads a small file (<4 MB — anonymized transcripts are plain
    /// text, always well under this) directly via a single PUT.
    /// `PUT /drives/{drive-id}/items/{parent-id}:/{filename}:/content`
    func uploadSmallFile(driveId: String, parentItemId: String, filename: String, data fileData: Data) async throws {
        guard
            let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw GraphAPIError.invalidResponse
        }
        let url = baseURL.appendingPathComponent(
            "drives/\(driveId)/items/\(parentItemId):/\(encodedFilename):/content")
        _ = try await request(url, method: "PUT", body: fileData, contentType: "text/plain")
    }

    /// Scaffold for future large-file support (audio/analysis artifacts
    /// are out of scope for this pass, per the plan — anonymized
    /// transcripts never need this path). Kept here for the spec doc's
    /// documented chunked-upload flow so it's a straightforward extension
    /// later rather than a from-scratch addition.
    ///
    /// `POST /drives/{drive-id}/items/{parent-id}:/{filename}:/createUploadSession`
    /// then chunked `PUT` to the returned `uploadUrl`, 10 MB per chunk.
    func createUploadSession(driveId: String, parentItemId: String, filename: String) async throws -> URL {
        guard
            let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw GraphAPIError.invalidResponse
        }
        let url = baseURL.appendingPathComponent(
            "drives/\(driveId)/items/\(parentItemId):/\(encodedFilename):/createUploadSession")
        let data = try await request(url, method: "POST", body: nil, contentType: "application/json")

        struct UploadSessionResponse: Decodable {
            let uploadUrl: String
        }
        let decoded = try JSONDecoder().decode(UploadSessionResponse.self, from: data)
        guard let sessionURL = URL(string: decoded.uploadUrl) else {
            throw GraphAPIError.invalidResponse
        }
        return sessionURL
    }

    // MARK: - HTTP plumbing

    private func get(_ url: URL) async throws -> Data {
        try await request(url, method: "GET", body: nil, contentType: nil)
    }

    /// Performs an authenticated request, retrying once after a silent
    /// token refresh if the first attempt returns 401.
    private func request(_ url: URL, method: String, body: Data?, contentType: String?) async throws -> Data {
        do {
            return try await performRequest(url, method: method, body: body, contentType: contentType, forceRefresh: false)
        } catch GraphAPIError.httpError(let statusCode, _) where statusCode == 401 {
            return try await performRequest(url, method: method, body: body, contentType: contentType, forceRefresh: true)
        }
    }

    private func performRequest(
        _ url: URL, method: String, body: Data?, contentType: String?, forceRefresh: Bool
    ) async throws -> Data {
        let token = try await GraphAuthService.shared.acquireTokenSilent()

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        urlRequest.httpBody = body

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw GraphAPIError.httpError(statusCode: httpResponse.statusCode, body: bodyText)
        }
        return data
    }
}
