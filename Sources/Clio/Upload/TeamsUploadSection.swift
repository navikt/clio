// TeamsUploadSection.swift
// Clio
//
// Upload widget shown in RecordingDetailView's right panel after transcription.
// Gate: transcript must exist AND researcher must have confirmed de-identification.
// Real Microsoft Graph upload — see TeamsUploadService.performGraphUpload
// and GraphClient. Tapping "Last opp til Teams" signs the researcher in
// (if needed) and then presents UploadConfirmationSheet for a final check
// before uploading to the one configured Teams channel — Clio has no
// "project" concept, just one destination every recording uploads to.

import SwiftUI

struct TeamsUploadSection: View {

    let recording: RecordingMeta

    @StateObject private var uploadService = TeamsUploadService.shared
    @ObservedObject private var authService = GraphAuthService.shared
    @State private var configurationErrorMessage: String?
    @State private var isSigningIn = false
    @State private var showingConfirmationSheet = false

    private var readiness: UploadReadiness {
        UploadGate.evaluate(recording: recording)
    }

    /// The one configured Teams destination. `nil` means it hasn't been
    /// set up yet in Settings.
    private var channel: TeamsChannelRef? {
        AppStateStore.load().teamsChannel
    }

    var body: some View {
        sectionBody
            .alert(
                "Kan ikke laste opp",
                isPresented: Binding(
                    get: { configurationErrorMessage != nil },
                    set: { if !$0 { configurationErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(configurationErrorMessage ?? "")
            }
            .sheet(isPresented: $showingConfirmationSheet) {
                if let channel {
                    UploadConfirmationSheet(
                        recording: recording,
                        onConfirmed: { remoteName in
                            showingConfirmationSheet = false
                            startUpload(channel: channel, remoteName: remoteName)
                        },
                        onCancel: { showingConfirmationSheet = false }
                    )
                }
            }
    }

    // MARK: - State machine

    @ViewBuilder
    private var sectionBody: some View {
        let r = readiness
        if case .uploading = r {
            uploadingView
        } else if case .alreadyUploaded(let uploadedAt, let remoteName) = r {
            uploadedView(uploadedAt: uploadedAt, remoteName: remoteName)
        } else if case .uploadFailed(let remoteName) = r {
            failedView(remoteName: remoteName)
        } else if case .ready(let remoteName) = r {
            readyView(remoteName: remoteName)
        } else if case .blockedNoTranscript = r {
            blockedView(
                icon: "waveform.and.mic",
                iconColor: .secondary,
                title: "Ingen transkripsjon",
                message: "Transkriber opptaket for å aktivere opplasting til Teams."
            )
        } else if case .blockedNotConfirmed = r {
            blockedView(
                icon: "lock.shield",
                iconColor: AppColors.accent,
                title: "Avidentifisering ikke bekreftet",
                message: "Bekreft avidentifisering i seksjonen over for å aktivere opplasting."
            )
        }
    }

    // MARK: - State views

    private func blockedView(
        icon: String,
        iconColor: Color,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readyView(remoteName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                    .font(.system(size: 14))
                Text("Klar for opplasting")
                    .font(.system(size: 13, weight: .medium))
            }
            Text(remoteName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button {
                beginUploadFlow()
            } label: {
                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Logger inn…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Last opp til Teams")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PillButtonStyle(variant: .primary))
            .disabled(isSigningIn)
        }
    }

    private var uploadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Laster opp…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uploadedView(uploadedAt: Date, remoteName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text("Lastet opp")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.success)
            }
            Text(remoteName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Lastet opp \(uploadedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func failedView(remoteName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppColors.destructive)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Opplasting feilet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Kontroller nettverkstilkobling og prøv igjen.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Button("Prøv igjen") {
                beginUploadFlow()
            }
            .buttonStyle(PillButtonStyle(variant: .primary))
        }
    }

    // MARK: - Actions

    /// Entry point for "Last opp til Teams" / "Prøv igjen". Checks the
    /// Teams channel is configured, signs the researcher in if needed (same
    /// button, no separate "Logg inn" state), and only then shows the
    /// confirmation sheet — signing in and confirming are two steps of one
    /// flow, not two separate actions the researcher has to trigger.
    private func beginUploadFlow() {
        guard !isSigningIn else { return }
        guard channel != nil else {
            configurationErrorMessage = """
            Ingen Teams-kanal er konfigurert ennå. Gå til Innstillinger → Teams.
            """
            return
        }
        if authService.signedIn {
            showingConfirmationSheet = true
            return
        }
        isSigningIn = true
        Task {
            do {
                try await authService.signInInteractive()
                isSigningIn = false
                showingConfirmationSheet = true
            } catch {
                print("🔑 TeamsUploadSection.beginUploadFlow: caught error: \(error)")
                isSigningIn = false
                configurationErrorMessage = error.localizedDescription
            }
        }
    }

    /// Starts the actual Graph upload to the one configured channel.
    private func startUpload(channel: TeamsChannelRef, remoteName: String) {
        Task {
            await uploadService.upload(recording: recording, channel: channel, remoteName: remoteName)
        }
    }
}
