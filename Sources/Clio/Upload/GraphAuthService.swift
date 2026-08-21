import AppKit
import Foundation
import MSAL

/// Errors surfaced by `GraphAuthService` to callers (upload UI, project
/// settings UI). Distinct from `GraphAPIError` (Sources/Clio/Upload/GraphClient.swift),
/// which covers errors from the actual Graph HTTP calls once a token exists.
enum GraphAuthError: LocalizedError {
    case notSignedIn
    case noPresentationContext
    case msal(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Ikke logget inn med Microsoft-kontoen din."
        case .noPresentationContext:
            return "Fant ikke et vindu å vise innloggingen i."
        case .msal(let underlying):
            return "Innlogging mot Microsoft feilet: \(underlying.localizedDescription)"
        }
    }
}

/// Wraps `MSALPublicClientApplication` to provide sign-in and token
/// acquisition against NAV's Entra ID tenant (see `EntraConfig`).
///
/// MSAL owns all token security: it persists tokens (access + refresh) in
/// the macOS Keychain internally, handles refresh-token exchange for
/// `acquireTokenSilent`, and drives the browser-based sign-in UI via
/// `ASWebAuthenticationSession` under the hood
/// (`MSALWebviewParameters`/`MSALInteractiveTokenParameters`). This class
/// only orchestrates *when* to call which MSAL entry point and exposes
/// sign-in state to SwiftUI.
///
/// We persist only the MSAL **account identifier** (`MSALAccount.identifier`)
/// across launches — never a token — so a returning user's silent token
/// acquisition can look up the same account without re-prompting for
/// which account to use.
@MainActor
final class GraphAuthService: ObservableObject {
    static let shared = GraphAuthService()

    @Published private(set) var signedIn: Bool = false
    @Published private(set) var accountDisplayName: String?

    private var application: MSALPublicClientApplication?
    private var currentAccount: MSALAccount?

    private static let accountIdentifierKey = "GraphAuthService.accountIdentifier"

    private init() {
        do {
            application = try Self.makeApplication()
            print("🔑 GraphAuthService: MSALPublicClientApplication constructed successfully")
        } catch {
            // Config error (bad client ID / redirect URI format) — should
            // only happen during development, never in a shipped build.
            print("⚠️ GraphAuthService: failed to construct MSALPublicClientApplication: \(error)")
            application = nil
        }
        restoreCachedAccountIfPresent()
    }

    private static func makeApplication() throws -> MSALPublicClientApplication {
        guard let authorityURL = URL(string: EntraConfig.authority) else {
            throw GraphAuthError.msal(
                NSError(domain: "GraphAuthService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Ugyldig authority-URL"]))
        }
        let authority = try MSALAADAuthority(url: authorityURL)
        let config = MSALPublicClientApplicationConfig(
            clientId: EntraConfig.clientID,
            redirectUri: EntraConfig.redirectURI,
            authority: authority)

        // Real root cause of the construction failure (found by reading
        // MSALPublicClientApplication's actual source): MSAL requires a
        // "broker capable" redirect URI (the msauth.<bundle-id>://auth
        // format) for work/school (non-consumer) AAD tenants like NAV's --
        // otherwise `initWithConfiguration:error:` silently returns nil.
        // Our redirect URI is a plain custom scheme (arm.nav://auth/callback),
        // registered as such in the Entra app registration and Info.plist,
        // which is not broker-capable. Setting this bypasses that specific
        // check (and disables brokered auth for this app, consistent with
        // MSALGlobalConfig.brokerAvailability = .none below).
        config.bypassRedirectURIValidation = true

        // Force MSAL to always use its own in-app webview
        // (ASWebAuthenticationSession) for interactive sign-in rather than
        // the default `.auto` behavior, which first tries the macOS system
        // SSO broker (Microsoft Authenticator / the AppSSO extension).
        // That broker is a *shared, system-wide* component — if it's stuck
        // for this account/tenant for any reason (e.g. an MFA-enrollment
        // requirement it can't complete silently, as seen for other
        // Microsoft apps on this Mac in Console.app), every broker-routed
        // app inherits the same failure, which surfaces here as sign-in
        // that never completes. Clio's own webview flow is self-contained
        // and unaffected by the broker's state.
        MSALGlobalConfig.brokerAvailability = .none

        return try MSALPublicClientApplication(configuration: config)
    }

    /// On launch, if we have a previously-signed-in account identifier
    /// cached, look it up via MSAL's own account store (no network call —
    /// this just reads MSAL's local Keychain-backed cache) so `signedIn`
    /// reflects reality immediately without requiring a fresh token fetch.
    private func restoreCachedAccountIfPresent() {
        guard let application,
            let identifier = UserDefaults.standard.string(forKey: Self.accountIdentifierKey)
        else { return }
        do {
            let account = try application.account(forIdentifier: identifier)
            currentAccount = account
            signedIn = true
            accountDisplayName = account.username
        } catch {
            // Account no longer in MSAL's cache (e.g. user removed it via
            // System Settings, or cache was cleared) — fall through to
            // signed-out state; a fresh interactive sign-in will recover.
        }
    }

    /// Triggers the browser-based OAuth sign-in flow. Must be called from
    /// a context where a window is on screen (uses the frontmost window's
    /// content view controller as the presentation anchor for MSAL's
    /// `ASWebAuthenticationSession`).
    func signInInteractive() async throws {
        print("🔑 GraphAuthService.signInInteractive: starting")
        guard let application else {
            print("🔑 GraphAuthService.signInInteractive: FAILED — application is nil (construction failed earlier, see the ⚠️ log line at launch)")
            throw GraphAuthError.notSignedIn
        }
        guard let viewController = Self.frontmostViewController() else {
            let windowInfo = NSApp.windows.map { "\($0.title.isEmpty ? "(untitled)" : $0.title): visible=\($0.isVisible), hasVC=\($0.contentViewController != nil)" }
            print("🔑 GraphAuthService.signInInteractive: FAILED — no presentation window found. keyWindow=\(NSApp.keyWindow != nil), mainWindow=\(NSApp.mainWindow != nil), all windows: \(windowInfo)")
            throw GraphAuthError.noPresentationContext
        }
        print("🔑 GraphAuthService.signInInteractive: presentation window found, calling MSAL acquireToken(with:)…")

        let webviewParameters = MSALWebviewParameters(authPresentationViewController: viewController)
        let parameters = MSALInteractiveTokenParameters(
            scopes: EntraConfig.scopes, webviewParameters: webviewParameters)

        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                if let error {
                    print("🔑 GraphAuthService.signInInteractive: MSAL returned an error: \(error)")
                    continuation.resume(throwing: GraphAuthError.msal(error))
                } else if let result {
                    print("🔑 GraphAuthService.signInInteractive: MSAL succeeded for account \(result.account.username ?? "?")")
                    continuation.resume(returning: result)
                } else {
                    print("🔑 GraphAuthService.signInInteractive: MSAL completion fired with neither a result nor an error (unexpected)")
                    continuation.resume(throwing: GraphAuthError.notSignedIn)
                }
            }
        }

        currentAccount = result.account
        UserDefaults.standard.set(result.account.identifier, forKey: Self.accountIdentifierKey)
        signedIn = true
        accountDisplayName = result.account.username
    }

    /// Returns a valid bearer token, refreshing silently via MSAL if
    /// needed. Falls back to an interactive sign-in only when silent
    /// acquisition fails with `MSALErrorInteractionRequired` (e.g. first
    /// use, or the refresh token was revoked) — any other silent-path
    /// error is surfaced directly rather than silently prompting the user
    /// unexpectedly mid-upload.
    ///
    /// - Parameter forceRefresh: When true, bypasses MSAL's cached access
    ///   token and forces a fresh refresh-token exchange. Used by
    ///   `GraphClient`'s retry-after-401 path — a plain re-call without
    ///   this would very likely hand back the same (already-rejected)
    ///   cached token, since MSAL's own proactive expiry buffer may not
    ///   have caught a token invalidated server-side before its stated
    ///   expiry.
    func acquireTokenSilent(forceRefresh: Bool = false) async throws -> String {
        guard let application else { throw GraphAuthError.notSignedIn }
        guard let account = currentAccount else {
            try await signInInteractive()
            guard let account = currentAccount else { throw GraphAuthError.notSignedIn }
            return try await acquireTokenSilent(application: application, account: account, forceRefresh: forceRefresh)
        }
        do {
            return try await acquireTokenSilent(application: application, account: account, forceRefresh: forceRefresh)
        } catch let error as NSError where error.domain == MSALErrorDomain
            && error.code == MSALError.interactionRequired.rawValue {
            try await signInInteractive()
            guard let refreshedAccount = currentAccount else { throw GraphAuthError.notSignedIn }
            return try await acquireTokenSilent(application: application, account: refreshedAccount, forceRefresh: forceRefresh)
        }
    }

    private func acquireTokenSilent(
        application: MSALPublicClientApplication, account: MSALAccount, forceRefresh: Bool
    ) async throws -> String {
        let parameters = MSALSilentTokenParameters(scopes: EntraConfig.scopes, account: account)
        parameters.forceRefresh = forceRefresh
        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: GraphAuthError.notSignedIn)
                }
            }
        }
        return result.accessToken
    }

    /// Signs out the current account, clearing both MSAL's cache and our
    /// persisted account identifier.
    func signOut() throws {
        guard let application, let account = currentAccount else { return }
        _ = try application.remove(account)
        currentAccount = nil
        signedIn = false
        accountDisplayName = nil
        UserDefaults.standard.removeObject(forKey: Self.accountIdentifierKey)
    }

    /// Finds a window to anchor MSAL's `ASWebAuthenticationSession`
    /// presentation to. Tries the key window first, then the main window,
    /// then any window with a content view controller at all — a SwiftUI
    /// `.sheet()` (like the Settings window sign-in is triggered from) is
    /// not always reported as "key" or "visible" at the exact moment this
    /// is checked, so filtering only on `.isVisible` was too strict and
    /// could fail to find a window that's genuinely on screen.
    private static func frontmostViewController() -> NSViewController? {
        if let vc = NSApp.keyWindow?.contentViewController {
            return vc
        }
        if let vc = NSApp.mainWindow?.contentViewController {
            return vc
        }
        for window in NSApp.windows {
            if let vc = window.contentViewController {
                return vc
            }
        }
        return nil
    }
}
