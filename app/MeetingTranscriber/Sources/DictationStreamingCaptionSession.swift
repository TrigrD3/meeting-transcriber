import AudioTapLib
@preconcurrency import AVFoundation
import Foundation
import os
import Speech

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DictationCaptions")

/// On-device Apple Dictation captions for one channel, behind the same pipeline
/// seam as Nemotron. Assets are checked/installed before construction by the
/// controller. Each analyzer input is consumed before accepting the next buffer,
/// leaving queue bounds and gap detection with `CaptionChannelFeed`.
///
/// Volatile results replace the channel hypothesis; final results carry their
/// matching 16 kHz audio from the bounded utterance ring for speaker matching.
/// A finished analyzer cannot be reused, so a recording stop or dropped-audio
/// reset retires it and the next ingest starts a fresh analysis timeline.
@available(macOS 26, *)
actor DictationStreamingCaptionSession: LiveCaptionPipeline {
    private let locale: Locale
    private let channelLabel: String
    private let onEvent: StreamingTranscriber.EventSink
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var analysisFormat: AVAudioFormat?
    private var lastSample: CMTime?
    private var analysisFrames: Int64 = 0
    private var generation = 0
    private var ring = UtteranceRingBuffer()
    private var lastPartial = ""

    init(
        locale: Locale,
        channelLabel: String,
        onEvent: @escaping StreamingTranscriber.EventSink,
    ) {
        self.locale = locale
        self.channelLabel = channelLabel
        self.onEvent = onEvent
    }

    deinit {
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }

    /// Prepares only installed system models. Asset download and fallback are
    /// owned by the controller, so this never blocks captions on installation.
    func prepare() async throws {
        guard analyzer == nil else { return }
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [],
        )
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                  compatibleWith: [transcriber], considering: inputFormat,
              )
        else { throw SessionError.audioFormatUnavailable }
        if inputFormat != analysisFormat {
            guard let converter = AVAudioConverter(from: inputFormat, to: analysisFormat)
            else { throw SessionError.audioFormatUnavailable }
            converter.primeMethod = .none
            self.converter = converter
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.prepareToAnalyze(in: analysisFormat)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        self.inputFormat = inputFormat
        self.analysisFormat = analysisFormat
        self.analyzer = analyzer
        let generation = generation
        let channelLabel = channelLabel
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    await self?.receive(result, generation: generation)
                }
            } catch is CancellationError {
                // The stream ends this way when we cancel the analyzer (reset, or a flush with no audio).
            } catch {
                guard !Task.isCancelled else { return }
                logger.warning("[\(channelLabel, privacy: .public)] results error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) async {
        guard buffer.channelCount == 1, buffer.sampleRate == 16000, !buffer.samples.isEmpty else { return }
        do {
            try await prepare()
            guard let inputFormat,
                  let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(buffer.samples.count)),
                  let channel = pcm.floatChannelData?[0]
            else { throw SessionError.audioFormatUnavailable }
            pcm.frameLength = AVAudioFrameCount(buffer.samples.count)
            buffer.samples.withUnsafeBufferPointer { samples in
                if let base = samples.baseAddress { channel.update(from: base, count: samples.count) }
            }
            let converted = try convert(pcm)
            ring.append(buffer.samples)
            if let converted { try await analyze(converted) }
        } catch {
            logger.warning("[\(self.channelLabel, privacy: .public)] ingest error: \(error.localizedDescription, privacy: .public)")
            await reset()
        }
    }

    /// Discards all old results before awaiting cancellation, so the result
    /// consumer cannot publish a late hypothesis across a dropped-audio gap.
    func reset() async {
        generation += 1
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        await resultsTask?.value
        clearSession()
        onEvent(.partial(""))
    }

    /// Finalize after the last consumed sample, then drain the result sequence
    /// before retiring the analyzer. The feed serializes this after all ingests.
    func flush() async {
        guard let analyzer else { return }
        do {
            if let tail = try convert(nil) { try await analyze(tail) }
            if let lastSample {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            logger.warning("[\(self.channelLabel, privacy: .public)] flush error: \(error.localizedDescription, privacy: .public)")
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
        clearSession()
    }

    private func analyze(_ pcm: AVAudioPCMBuffer) async throws {
        guard let analyzer, let analysisFormat else { return }
        let start = CMTime(value: analysisFrames, timescale: CMTimeScale(analysisFormat.sampleRate))
        analysisFrames += Int64(pcm.frameLength)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: pcm, bufferStartTime: start))
        continuation.finish()
        lastSample = try await analyzer.analyzeSequence(stream)
    }

    private func receive(_ result: DictationTranscriber.Result, generation: Int) {
        guard generation == self.generation else { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            lastPartial = ""
            let start = result.range.start.seconds
            let end = CMTimeRangeGetEnd(result.range).seconds
            let audio = !text.isEmpty && start.isFinite && end.isFinite
                ? ring.extract(fromMs: Int(start * 1000), toMs: Int(end * 1000))
                : []
            Self.finalEvents(text, audio: audio).forEach(onEvent)
        } else if text != lastPartial {
            lastPartial = text
            onEvent(.partial(text))
        }
    }

    /// An empty final clears the hypothesis. A long one is split into lines of at most
    /// `StreamingCaptionSplitter.defaultMaxWords`, the utterance audio going with the first
    /// line only, like the other streaming backends. The splitter needs a prefix-monotonic
    /// transcript, which volatile results are not documented to be, so only finals go through it.
    static func finalEvents(_ text: String, audio: [Float]) -> [StreamingTranscriber.Event] {
        guard !text.isEmpty else { return [.partial("")] }
        var splitter = StreamingCaptionSplitter()
        return splitter.update(text, audioTime: 0, finalize: true).finals.enumerated().map { index, line in
            .finalized(text: line, audio: index == 0 ? audio : [])
        }
    }

    private func clearSession() {
        analyzer = nil
        resultsTask = nil
        converter = nil
        inputFormat = nil
        analysisFormat = nil
        lastSample = nil
        analysisFrames = 0
        ring = UtteranceRingBuffer()
        lastPartial = ""
    }

    /// nil input drains the converter at recording stop. The converter is kept
    /// across buffers so fractional resampling frames are not lost per callback.
    private func convert(_ input: AVAudioPCMBuffer?) throws -> AVAudioPCMBuffer? {
        guard let converter else { return input }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { throw SessionError.audioFormatUnavailable }
        let feed = DictationConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        if let error { throw error }
        guard status != .error else { throw SessionError.audioConversionFailed }
        return output.frameLength > 0 ? output : nil
    }

    private enum SessionError: Error {
        case audioFormatUnavailable
        case audioConversionFailed
    }
}

/// `AVAudioConverter` invokes its Sendable input block synchronously; this box
/// is local to one conversion and never accessed from another thread.
private final class DictationConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private var fed = false

    init(_ buffer: AVAudioPCMBuffer?) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .endOfStream
            return nil
        }
        guard !fed else {
            status.pointee = .noDataNow
            return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
    }
}
