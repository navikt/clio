import Foundation

// MARK: - Model

/// Clio always transcribes with the large NB-Whisper model — the smaller
/// variants (tiny/base/medium) were never actually bundled and all
/// silently routed to this same model anyway (see
/// `NativeTranscriptionEngine`), so the size choice was removed entirely
/// rather than left as a misleading picker.
enum TranscriptionModel: String, CaseIterable, Identifiable, Codable {
    case large

    var id: String { rawValue }

    /// Norwegian display name shown in the UI.
    var displayName: String {
        "Stor"
    }

    /// Approximate RAM requirement for the model.
    var estimatedRAM: String {
        "~8 GB"
    }

    /// Norwegian description shown in the settings UI.
    var modelDescription: String {
        "Høyest nøyaktighet."
    }
}
