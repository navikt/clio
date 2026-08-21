// TeamsSettingsView.swift
// Clio
//
// Teams configuration UI: the single Teams channel every upload goes to,
// plus the Microsoft sign-in used for the upload. Clio has no "project"
// concept — one channel, set once, used by every recording.
//
// Channel selection is always manual entry (Team ID + Channel ID pasted in
// by the researcher); the granted Graph scopes don't support a "browse my
// Teams" picker.

import SwiftUI

struct TeamsSettingsView: View {
    @ObservedObject private var authService = GraphAuthService.shared

    @State private var channel: TeamsChannelRef = AppStateStore.load().teamsChannel ?? TeamsChannelRef()
    @State private var errorMessage: String?
    @State private var isResolvingChannel = false
    @State private var channelAgeNotice: String?

    // Draft fields — edited in a local buffer, only written back to
    // AppState on explicit Save.
    @State private var draftTeamId = ""
    @State private var draftChannelId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            signInSection
            Divider()
            teamsChannelSection
        }
        .padding(AppSpacing.xl)
        .frame(width: 520)
        .onAppear { syncDraftFromSelection() }
    }

    // MARK: - Sign-in section

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader("Microsoft-pålogging", systemImage: "person.crop.circle.badge.checkmark")

            GroupBox {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: authService.signedIn ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(authService.signedIn ? .green : .secondary)

                    if authService.signedIn, let name = authService.accountDisplayName {
                        Text("Logget inn som \(name)")
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text("Ikke logget inn")
                            .font(.system(size: 13, weight: .medium))
                    }

                    Spacer()

                    Button(authService.signedIn ? "Logg ut" : "Logg inn") {
                        Task { await toggleSignIn() }
                    }
                    .buttonStyle(HoverButtonStyle())
                }
                .padding(AppSpacing.sm)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func toggleSignIn() async {
        errorMessage = nil
        do {
            if authService.signedIn {
                try authService.signOut()
            } else {
                try await authService.signInInteractive()
            }
        } catch {
            print("🔑 TeamsSettingsView.toggleSignIn: caught error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Teams channel section

    private var teamsChannelSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader("Teams-kanal", systemImage: "person.2.badge.gearshape")

            Text("""
            Lim inn Team-ID og Kanal-ID for den private, sikkerhetskopi-utelukkede \
            Teams-kanalen opptak skal lastes opp til. Clio oppretter aldri kanaler selv.
            """)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Team-ID (GUID)", text: $draftTeamId)
            TextField("Kanal-ID (GUID)", text: $draftChannelId)

            if channel.isReadyForUpload {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Kanal konfigurert og klar for opplasting")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let notice = channelAgeNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(AppCopy.Common.save) {
                    Task { await saveChannel() }
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(isResolvingChannel || draftTeamId.isEmpty || draftChannelId.isEmpty)
            }
        }
    }

    private func syncDraftFromSelection() {
        draftTeamId = channel.teamId
        draftChannelId = channel.channelId
        channelAgeNotice = nil
    }

    /// Resolves the channel's drive/files-folder and estimates its
    /// creation date via `GraphClient`, then persists the result.
    /// Surfaces the channel-age result immediately, at configuration
    /// time, rather than deferring it to the first upload attempt.
    private func saveChannel() async {
        errorMessage = nil
        channelAgeNotice = nil
        isResolvingChannel = true
        defer { isResolvingChannel = false }

        do {
            let folder = try await GraphClient.shared.resolveChannelFilesFolder(
                teamId: draftTeamId, channelId: draftChannelId)
            let createdAt = try await GraphClient.shared.estimateChannelCreatedDate(
                teamId: draftTeamId, channelId: draftChannelId)

            var updated = TeamsChannelRef(teamId: draftTeamId, channelId: draftChannelId)
            updated.channelCreatedAt = createdAt
            updated.driveId = folder.driveId
            updated.filesFolderItemId = folder.itemId

            let ageCheck = try GraphClient.assertChannelAgeOK(createdAt: createdAt)
            if ageCheck == .unknown {
                channelAgeNotice = """
                Kunne ikke bekrefte når kanalen ble opprettet (ingen meldingshistorikk å \
                anslå ut fra). Vent minst 24 timer etter at kanalen ble opprettet før du \
                laster opp, av hensyn til utelukkelse fra sikkerhetskopiering.
                """
            }

            channel = updated
            persistChannel()
        } catch GraphAPIError.channelTooNew(let createdAt, let hoursRemaining) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.locale = Locale(identifier: "nb_NO")
            channelAgeNotice = """
            Kanalen ble opprettet \(formatter.string(from: createdAt)) — vent ca. \
            \(Int(hoursRemaining.rounded(.up))) time(r) til før du kan bruke den, av \
            hensyn til utelukkelse fra sikkerhetskopiering.
            """
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistChannel() {
        do {
            _ = try AppStateStore.update { $0.teamsChannel = channel }
        } catch {
            errorMessage = "Kunne ikke lagre Teams-innstillinger: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
