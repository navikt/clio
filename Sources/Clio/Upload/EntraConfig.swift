// EntraConfig.swift
// Clio
//
// Microsoft Entra ID (Azure AD) configuration for NAV's tenant.
//
// The enterprise app is registered in NAV's tenant as "Audio Recording Manager"
// (display name — ask NAV IT to rename to "Clio" when convenient; the IDs below
// remain unchanged). Clio is the OAuth client; NAV's tenant is the authority.
//
// OAuth flow: Authorization Code + PKCE (no client secret required for public
// native clients). The redirect URI uses a custom scheme registered in Info.plist.
// MSAL (Sources/Clio/Upload/GraphAuthService.swift) drives the actual flow.
//
// Scopes granted to the enterprise app:
//   Files.ReadWrite         — write transcript files to SharePoint/OneDrive
//   Sites.ReadWrite.All     — access Teams channel file libraries
//   User.Read               — read signed-in user profile (display name, UPN)
//   ChannelMessage.Read.All — used by GraphClient.estimateChannelCreatedDate(...)
//                             to approximate a channel's creation time for the
//                             24-hour backup-exclusion compliance guard. Direct
//                             channel metadata (which has a real createdDateTime)
//                             needs Channel.ReadBasic.All, which was NOT granted,
//                             so this is a best-effort heuristic, not exact.

import Foundation

enum EntraConfig {

    /// NAV's Entra tenant ID.
    static let tenantID = "62366534-1ec3-4962-8869-9b5535279d0b"

    /// Application (client) ID of the "Audio Recording Manager" enterprise app
    /// registered in NAV's tenant. NAV IT can rename the display name to "Clio"
    /// without changing this value.
    static let clientID = "db6ed259-83be-4d4e-9329-00c4923d4708"

    /// Custom URI scheme redirect — registered in Info.plist under
    /// CFBundleURLSchemes. The Entra app registration must list this exactly.
    static let redirectURI = "arm.nav://auth/callback"

    /// OAuth 2.0 / OIDC authority endpoint for the NAV tenant.
    static let authority = "https://login.microsoftonline.com/\(tenantID)"

    /// Microsoft Graph base URL.
    static let graphBaseURL = URL(string: "https://graph.microsoft.com/v1.0")!

    /// Scopes to request during sign-in. "offline_access" is added automatically
    /// by MSAL; list only the resource-level scopes here.
    static let scopes: [String] = [
        "https://graph.microsoft.com/Files.ReadWrite",
        "https://graph.microsoft.com/Sites.ReadWrite.All",
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/ChannelMessage.Read.All",
    ]
}
