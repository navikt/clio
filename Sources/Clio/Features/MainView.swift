import Foundation
import SwiftUI

// MARK: - Main View
struct MainView: View {
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared
    @ObservedObject private var transcriptionService = TranscriptionService.shared

    @State private var selectedTab: AppTab = .record
    @State private var selectedRecording: RecordingItem? = nil
    @State private var showAbout = false
    @State private var showLogViewer = false
    @State private var showDesignShowcase = false
    @State private var showSettings = false
    @State private var settingsTab: SettingsTab = .transcription
    @State private var airDropToast: String?

    var body: some View {
        // NavigationSplitView wrapper is REQUIRED for SwiftUI's unified
        // chrome to extend content to the window's outer rounded frame.
        // See `Design/WindowChrome.swift` — bare HStack at root breaks
        // the corner-radius pipeline. The actual nav lives inside detail.
        NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
            EmptyView()
        } detail: {
            HStack(spacing: 0) {
                NavPanel(
                    selectedTab: $selectedTab,
                    showAbout: $showAbout
                )
                .frame(width: 64)

                Divider()

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar(removing: .sidebarToggle)
        }
        .overlay(alignment: .top) {
            VStack(spacing: AppSpacing.sm) {
                if let toast = airDropToast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.sm)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.quaternary))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                modelDownloadBanner
            }
            .padding(.top, AppSpacing.md)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 700)
        .sheet(isPresented: $showAbout) {
            AboutView().presentationDetents([.large])
        }
        .sheet(isPresented: $showLogViewer) {
            PasswordGateView(isPresented: $showLogViewer)
        }
        .sheet(isPresented: $showDesignShowcase) {
            DesignShowcaseView(isPresented: $showDesignShowcase)
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text(AppCopy.Common.settings)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(AppCopy.Common.close) { showSettings = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                Picker("", selection: $settingsTab) {
                    Text("Transkripsjon").tag(SettingsTab.transcription)
                    Text("Teams").tag(SettingsTab.teams)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 24)
                .padding(.top, 12)
                ScrollView {
                    switch settingsTab {
                    case .transcription:
                        TranscriptionSettingsView()
                    case .teams:
                        TeamsSettingsView()
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 500)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowLogViewer"))) { _ in
            showLogViewer = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowDesignShowcase"))) { _ in
            showDesignShowcase = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowSettings"))) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AirDropImportWatcher.didImportNotification)) { note in
            let filename = (note.userInfo?["filename"] as? String) ?? ""
            withAnimation { airDropToast = AppCopy.MobileTransfer.airDropImportedBody(filename) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { airDropToast = nil }
            }
        }
        .onChange(of: selectedTab) { _, _ in autoSelectFirst() }
        .onChange(of: recordingsManager.recordings) { _, _ in
            if selectedTab == .recordings { autoSelectFirst() }
        }
        .onAppear { /* RecordingsManager loads on init and stays in sync via notifications */ }
    }

    @ViewBuilder
    private var modelDownloadBanner: some View {
        switch transcriptionService.modelDownloadState {
        case .idle:
            EmptyView()
        case .downloading(let model, let message):
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.75)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Laster ned NB-Whisper \(model.displayName)…")
                        .font(.system(size: 13, weight: .medium))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .padding(.horizontal, AppSpacing.lg)
        case .ready(let model):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("NB-Whisper \(model.displayName) er lastet ned. Transkribering er nå mulig.")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .padding(.horizontal, AppSpacing.lg)
        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .padding(.horizontal, AppSpacing.lg)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .record:
            RecordingView(recorder: audioRecorder, isShowing: .constant(true))
        case .recordings:
            BibliotekScreen(
                recordingsManager: recordingsManager,
                audioPlayer: audioPlayer,
                selectedRecording: $selectedRecording
            )
        case .mobileTransfer:
            MobileTransferScreen()
        }
    }

    private func autoSelectFirst() {
        switch selectedTab {
        case .record:
            break
        case .recordings:
            if selectedRecording == nil {
                selectedRecording = recordingsManager.recordings.first
            }
        case .mobileTransfer:
            break
        }
    }
}

/// Which panel the settings sheet shows. Kept private to `MainView` since
/// it's purely a UI-navigation concern, not app state.
private enum SettingsTab {
    case transcription
    case teams
}
