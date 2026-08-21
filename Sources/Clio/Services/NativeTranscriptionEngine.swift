import Foundation
import WhisperKit

/// Wraps WhisperKit (on-device CoreML speech-to-text) as a drop-in
/// replacement for the `no-transcribe` Python subprocess bridge.
///
/// Runs fully in-process via CoreML/ANE — no child executable, no sandbox
/// entitlement conflict. The bundled model is the official
/// `NbAiLab/nb-whisper-large` weights, converted to WhisperKit's CoreML
/// format via `whisperkittools` (see `packaging/convert_nb_whisper.md` for
/// the conversion recipe). This is the only model Clio uses — the smaller
/// tiny/base/medium variants were never bundled and the model-size choice
/// was removed entirely rather than left as a misleading picker.
actor NativeTranscriptionEngine {
    static let shared = NativeTranscriptionEngine()

    private var pipe: WhisperKit?
    private var loadError: Error?

    private init() {}

    private static var modelFolderURL: URL? {
        Bundle.main.url(forResource: "NbAiLab_nb-whisper-large", withExtension: nil, subdirectory: "WhisperKitModels")
    }

    private static var tokenizerFolderURL: URL? {
        modelFolderURL?.appendingPathComponent("tokenizer")
    }

    /// True once the bundled model folder is present in the app bundle.
    /// Does not guarantee the model has loaded successfully yet — call
    /// `ensureLoaded()` for that.
    static var isBundled: Bool {
        modelFolderURL != nil
    }

    private func ensureLoaded() async throws -> WhisperKit {
        if let pipe = pipe { return pipe }
        if let loadError = loadError { throw loadError }

        guard let modelFolder = Self.modelFolderURL else {
            let error = TranscriptionError.processFailed("Innebygd NB-Whisper-modell mangler i appbunten.")
            self.loadError = error
            throw error
        }

        do {
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: Self.tokenizerFolderURL,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let newPipe = try await WhisperKit(config)
            self.pipe = newPipe
            return newPipe
        } catch {
            self.loadError = error
            throw TranscriptionError.processFailed("Kunne ikke laste NB-Whisper-modell: \(error.localizedDescription)")
        }
    }

    /// Transcribes a 16kHz mono WAV file and returns Clio's own
    /// `TranscriptionResult` model (same contract the Python `no-transcribe`
    /// bridge used to produce), with every segment's speaker set to
    /// `speakerLabel` (diarization, when it runs, overwrites this afterward
    /// — same convention as the old subprocess path).
    func transcribe(
        wavPath: String, language: String, speakerLabel: String, durationSeconds: Double
    ) async throws -> TranscriptionResult {
        let whisperKit = try await ensureLoaded()

        var options = DecodingOptions()
        options.language = language
        options.wordTimestamps = true
        options.task = .transcribe
        options.usePrefillPrompt = true
        options.detectLanguage = false
        // Without this, per-segment `text` includes raw special tokens
        // (<|startoftranscript|>, <|no|>, <|transcribe|>, timestamp tokens,
        // <|endoftext|>) that would otherwise leak into the transcript
        // shown to researchers. Confirmed via a real end-to-end smoke test.
        options.skipSpecialTokens = true

        let segments: [TranscriptionSegment]
        do {
            segments = try await self.transcribeAndConvert(
                whisperKit: whisperKit, wavPath: wavPath, options: options, speakerLabel: speakerLabel)
        } catch {
            throw TranscriptionError.processFailed("WhisperKit-transkripsjon feilet: \(error.localizedDescription)")
        }

        return TranscriptionResult(
            version: "1.0", model: "NbAiLab/nb-whisper-large (native WhisperKit)",
            language: language, durationSeconds: durationSeconds, numSpeakers: 1,
            segments: segments,
            metadata: TranscriptionResultMetadata(
                inputFile: (wavPath as NSString).lastPathComponent,
                processingTimeSeconds: 0,
                modelVariant: "nb-whisper-large", computeType: "coreml-ane", device: "ane",
                diarizationRun: false))
    }

    /// Runs WhisperKit's own `transcribe(audioPath:decodeOptions:)` and
    /// converts its result segments to Clio's `TranscriptionSegment` model.
    ///
    /// Kept as a separate method (rather than inlined in `transcribe(wavPath:...)`)
    /// so WhisperKit's own `TranscriptionResult` type never needs to be
    /// spelled out explicitly — it's ambiguous with Clio's own
    /// `TranscriptionResult` struct (the WhisperKit *module* shares its name
    /// with the `WhisperKit` class, which breaks `WhisperKit.TranscriptionResult`
    /// module-qualified lookup). Returning `[TranscriptionSegment]`
    /// (unambiguous) lets Swift fully infer the intermediate WhisperKit type.
    private func transcribeAndConvert(
        whisperKit: WhisperKit, wavPath: String, options: DecodingOptions, speakerLabel: String
    ) async throws -> [TranscriptionSegment] {
        let results = try await whisperKit.transcribe(audioPath: wavPath, decodeOptions: options)

        var segments: [TranscriptionSegment] = []
        var segId = 0
        for result in results {
            for seg in result.segments {
                var words: [TranscriptionWord] = []
                for w in seg.words ?? [] {
                    let word = TranscriptionWord(
                        word: w.word,
                        start: Double(w.start),
                        end: Double(w.end),
                        confidence: Double(w.probability))
                    words.append(word)
                }
                let trimmedText = seg.text.trimmingCharacters(in: CharacterSet.whitespaces)
                let confidence: Double = max(0, min(1, 1.0 + Double(seg.avgLogprob)))
                let segment = TranscriptionSegment(
                    id: segId,
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: trimmedText,
                    speaker: speakerLabel,
                    confidence: confidence,
                    words: words)
                segments.append(segment)
                segId += 1
            }
        }
        return segments
    }
}
