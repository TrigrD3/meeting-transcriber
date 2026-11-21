import Foundation

// Dictation pipeline construction stays behind the same factory boundary as
// Nemotron, so controller routing and fallback tests never contact Speech services.
extension LiveTranscriptionController {
    typealias DictationPipelineFactory = @MainActor (
        _ language: String,
        _ makeSink: (LiveCaptionChannel) -> StreamingTranscriber.EventSink,
    ) async throws -> (mic: any LiveCaptionPipeline, app: any LiveCaptionPipeline)?

    static func makeDefaultDictationPipelines(
        language: String,
        makeSink: (LiveCaptionChannel) -> StreamingTranscriber.EventSink,
    ) async throws -> (mic: any LiveCaptionPipeline, app: any LiveCaptionPipeline)? {
        guard #available(macOS 26, *),
              let locale = await DictationCaptionSupport.shared.readyLocale(for: language)
        else { return nil }
        let mic = DictationStreamingCaptionSession(
            locale: locale, channelLabel: "mic", onEvent: makeSink(.mic),
        )
        try await mic.prepare()
        let app = DictationStreamingCaptionSession(
            locale: locale, channelLabel: "app", onEvent: makeSink(.app),
        )
        try await app.prepare()
        return (mic, app)
    }
}
