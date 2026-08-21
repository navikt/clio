import SwiftUI

// MARK: - Settings View

/// Settings panel for no-transcribe configuration.
/// Shows installation status and per-run defaults. Clio always transcribes
/// with the large NB-Whisper model — there is no model size to choose.
struct TranscriptionSettingsView: View {
    @ObservedObject private var service = TranscriptionService.shared

    // Persisted defaults
    @AppStorage("transcription.verbatim")        private var verbatim = false
    @AppStorage("transcription.language")        private var language = "no"
    @AppStorage("transcription.validateMode")    private var validateMode = "warn"
    @AppStorage("transcription.numBeams")        private var numBeams = 3
    // Transient UI state
    @State private var installState: ActionState = .idle
    @State private var updateState: ActionState = .idle
    @State private var versionString: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                installSection
                Divider()
                defaultsSection
            }
            .padding(24)
        }
        .frame(width: 480)
        .onAppear { loadVersion() }
    }

    // MARK: - Install section

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Installasjon", systemImage: "wrench.and.screwdriver")

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Status row
                    HStack(spacing: 8) {
                        Image(systemName: service.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(service.isInstalled ? .green : .red)
                        Text(service.isBundledRuntime ? "no-transcribe følger med appen" : service.isInstalled ? "no-transcribe er installert" : "no-transcribe er ikke installert")
                            .font(.system(size: 13, weight: .medium))

                        if let ver = versionString {
                            Text("(\(ver))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    // Install / Update buttons
                    HStack(spacing: 8) {
                        if service.isBundledRuntime {
                           Text("Python-miljøet er pakket inn i appen for sandboxet distribusjon.")
                               .font(.system(size: 11))
                               .foregroundStyle(.secondary)
                               .fixedSize(horizontal: false, vertical: true)
                        } else if !service.isInstalled {
                           ActionButton(
                               label: "Installer",
                               systemImage: "arrow.down.circle",
                               state: installState
                           ) {
                               performInstall()
                           }
                        } else {
                           ActionButton(
                               label: "Oppdater",
                               systemImage: "arrow.triangle.2.circlepath",
                               state: updateState
                           ) {
                               performUpdate()
                           }
                        }
                    }

                    if case .downloading(let model, let message) = service.modelDownloadState {
                        HStack(spacing: 8) {
                           ProgressView()
                               .progressViewStyle(.circular)
                               .scaleEffect(0.65)
                           Text("NB-Whisper \(model.displayName) lastes ned")
                               .font(.system(size: 11))
                               .foregroundStyle(.secondary)
                           Text(message)
                               .font(.system(size: 11))
                               .foregroundStyle(.secondary)
                           Spacer()
                        }
                    } else if case .ready(let model) = service.modelDownloadState {
                        HStack(spacing: 8) {
                           Image(systemName: "checkmark.circle.fill")
                               .foregroundStyle(.green)
                           Text("NB-Whisper \(model.displayName) er lastet ned. Transkribering er nå mulig.")
                               .font(.system(size: 11))
                               .foregroundStyle(.secondary)
                           Spacer()
                        }
                    } else if case .failed(let message) = service.modelDownloadState {
                        HStack(spacing: 8) {
                           Image(systemName: "exclamationmark.triangle.fill")
                               .foregroundStyle(.orange)
                           Text(message)
                               .font(.system(size: 11))
                               .foregroundStyle(.secondary)
                           Spacer()
                        }
                    }

                    if !service.isInstalled {
                        Text(service.isBundledRuntime ? "Bundled Python brukes i TestFlight/App Store-bygget." : "Krever Python 3.9+ og internettilgang for nedlasting av pakken.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    // MARK: - Defaults section

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Standardinnstillinger", systemImage: "slider.horizontal.3")

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {

                    // Transkripsjonsformat
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Transkripsjonsformat") {
                            Picker("", selection: $verbatim) {
                                Text("Renset").tag(false)
                                Text("Ordrett").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            if verbatim {
                                Text("Alle lyder skrives ned nøyaktig slik de ble sagt – fyllord (ehm, liksom), nøling og gjentakelser tas med.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Bruk dette når du analyserer talemønstre eller trenger fullstendig kilde.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Fyllord (ehm, liksom), nøling og gjentakelser fjernes automatisk. Gir flytende tekst klar for analyse.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Anbefalt for de fleste intervjuer.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppColors.accent.opacity(0.8))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    // Transcription precision
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Transkripsjonsnøyaktighet") {
                            Picker("", selection: $numBeams) {
                                Text("Raskest – mer manuell retting").tag(1)
                                Text("Rask – anbefalt").tag(2)
                                Text("Middels – god balanse").tag(3)
                                Text("Treg – høy nøyaktighet").tag(4)
                                Text("Svært treg – best mulig").tag(5)
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        Text(numBeamsDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    // Language picker
                    LabeledContent("Språk") {
                        Picker("", selection: $language) {
                            Text("Bokmål").tag("no")
                            Text("Nynorsk").tag("nn")
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    Divider()

                    // Validation mode
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Kvalitetskontroll") {
                            Picker("", selection: $validateMode) {
                                Text("Advar (anbefalt)").tag("warn")
                                Text("Merk usikre").tag("flag")
                                Text("Prøv på nytt").tag("retry")
                                Text("Av").tag("none")
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        Text(validateModeDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var numBeamsDescription: String {
        switch numBeams {
        case 1: return "Raskest mulig, men modellen tar snarveier og hopper over usikker tale. Forvent hyppigere feil som du må rette manuelt."
        case 2: return "Rask med god kvalitet. Anbefalt for de fleste intervjuer."
        case 3: return "Noe tregere, men fanger opp mer tvetydig tale. Bra for opptak med mye bakgrunnsstøy eller sterke dialekter."
        case 4: return "Treg. Brukes til opptak der nøyaktighet er viktigere enn ventetid."
        case 5: return "Svært treg (3–5× lenger enn rask). Bruk kun når du absolutt trenger best mulig resultat."
        default: return ""
        }
    }

    private var validateModeDescription: String {
        switch validateMode {
        case "warn":  return "Logger potensielle problemer (hull, gjentakelser, hallusinasjoner) til diagnoseloggen uten å endre resultatet."
        case "flag":  return "Markerer usikre segmenter i JSON-utdataene. Disse kan vises dempet i editoren."
        case "retry": return "Transkriberer usikre regioner på nytt med høyere beam-bredde (saktere, men mer nøyaktig)."
        case "none":  return "Ingen kvalitetskontroll kjøres etter transkripsjon."
        default:      return ""
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

    private func loadVersion() {
        Task {
            await MainActor.run {
                versionString = "NB-Whisper-large (WhisperKit / CoreML)"
            }
        }
    }

    private func performInstall() {
        installState = .running
        Task {
            do {
                try await service.install()
                await MainActor.run { installState = .success }
                loadVersion()
            } catch {
                await MainActor.run { installState = .failed(error.localizedDescription) }
            }
        }
    }

    private func performUpdate() {
        updateState = .running
        Task {
            do {
                try await service.update()
                await MainActor.run { updateState = .success }
                loadVersion()
            } catch {
                await MainActor.run { updateState = .failed(error.localizedDescription) }
            }
        }
    }
}

// MARK: - Action state

private enum ActionState: Equatable {
    case idle
    case running
    case success
    case failed(String)
}

// MARK: - Action Button

private struct ActionButton: View {
    let label: String
    let systemImage: String
    let state: ActionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch state {
                case .idle, .failed:
                    Image(systemName: systemImage)
                    Text(label)
                case .running:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.65)
                    Text(label + "...")
                case .success:
                    Image(systemName: "checkmark")
                    Text("Fullført")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state == .running)
    }
}
