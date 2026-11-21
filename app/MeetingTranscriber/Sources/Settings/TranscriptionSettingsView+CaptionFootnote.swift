// The live-caption backend footnote, split out of TranscriptionSettingsView (file-length cap).

extension TranscriptionSettingsView {
    /// Describes the backend `LiveCaptionsGate` selects for the current transcription
    /// language: English → Parakeet EOU, a language Nemotron was trained on → Nemotron
    /// streaming, an on-device Dictation locale → Apple Dictation, any other language → the
    /// standard re-transcribe engine; auto-detect too, unless the engine detects English first.
    static func captionBackendFootnote(
        strategy: LiveCaptionsGate.Strategy,
        languageIsSet: Bool,
        detectsLanguage: Bool,
    ) -> String {
        switch strategy {
        case .englishStreaming:
            "Caption backend follows your transcription language. English uses the "
                + "low-latency Parakeet streaming model."

        case .nemotronStreaming:
            "Caption backend follows your transcription language. It uses the low-latency "
                + "Nemotron multilingual streaming model (~0.6-0.7 GB, downloads on first use)."

        case .dictationStreaming:
            "Caption backend follows your transcription language. It uses on-device Apple Dictation. "
                + "Its speech assets download automatically; until they are ready, captions use the "
                + "standard re-transcribe engine."

        // `.none` cannot be reached with a language set: both engines support re-transcribe.
        case .reTranscribe, .none:
            if languageIsSet {
                "Caption backend follows your transcription language. This language has no "
                    + "low-latency streaming model, so captions use the standard re-transcribe engine."
            } else if detectsLanguage {
                "Caption backend follows your transcription language. Auto-detect listens to the first few seconds of speech: "
                    + "English then streams through the low-latency Parakeet model; other languages use the standard re-transcribe engine."
            } else {
                "Caption backend follows your transcription language. Auto-detect uses the "
                    + "standard re-transcribe engine; set a specific language for low-latency streaming captions."
            }
        }
    }
}
