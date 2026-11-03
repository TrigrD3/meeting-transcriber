import AVFoundation
import Foundation

/// Cuts a long recording into WAV pieces for cloud transcription, whose
/// providers cap an upload at 25 MB. Each cut lands at the quietest short
/// frame in a search window before the piece boundary, so a word is not split;
/// with no quiet frame there it falls on the boundary itself.
enum CloudAudioSplitter {
    /// Ten minutes of 16 kHz 16-bit mono is about 19 MB.
    static let defaultPieceDuration: TimeInterval = 600
    static let defaultSearchWindow: TimeInterval = 60
    /// Long enough that a dip inside a word does not qualify as a pause.
    static let frameDuration: TimeInterval = 0.2
    /// A frame at or below this RMS counts as a pause.
    static let quietThresholdDB: Float = -40

    /// Sample offset into `window` at the centre of its quietest frame, or nil
    /// when no frame is quiet. Ties go to the later frame, keeping pieces long.
    static func quietCut(in window: [Float], sampleRate: Double) -> Int? {
        let frameLength = max(1, Int(frameDuration * sampleRate))
        var best: (offset: Int, level: Float)?
        var start = 0
        while start + frameLength <= window.count {
            let level = AudioMixer.rmsDecibels(samples: window[start ..< start + frameLength])
            if level <= quietThresholdDB, level <= best?.level ?? .infinity {
                best = (start + frameLength / 2, level)
            }
            start += frameLength
        }
        return best?.offset
    }

    /// Frame ranges covering `totalFrames`, each at most `pieceFrames` long.
    /// `readWindow` returns the samples of the given range, so only the search
    /// windows are ever in memory.
    static func planPieces(
        totalFrames: Int,
        pieceFrames: Int,
        windowFrames: Int,
        sampleRate: Double,
        readWindow: (Range<Int>) throws -> [Float],
    ) rethrows -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = 0
        while totalFrames - start > pieceFrames {
            let boundary = start + pieceFrames
            let windowStart = max(start + 1, boundary - windowFrames)
            let window = try readWindow(windowStart ..< boundary)
            let cut = quietCut(in: window, sampleRate: sampleRate).map { windowStart + $0 } ?? boundary
            pieces.append(start ..< cut)
            start = cut
        }
        pieces.append(start ..< totalFrames)
        return pieces
    }

    /// Plans the pieces of the WAV at `url`; a single piece means no split.
    static func planPieces(
        of url: URL, pieceDuration: TimeInterval, searchWindow: TimeInterval,
    ) throws -> (pieces: [Range<Int>], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let pieces = try planPieces(
            totalFrames: Int(file.length),
            pieceFrames: max(1, Int(pieceDuration * rate)),
            windowFrames: Int(searchWindow * rate),
            sampleRate: rate,
        ) { range in
            let buffer = try read(file, range: range)
            // swiftlint:disable:next force_unwrapping
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return (pieces, rate)
    }

    /// Writes `range` of `source` to `destination` as 16-bit PCM, a chunk at a
    /// time, whatever the source's sample format.
    static func writePiece(of source: URL, range: Range<Int>, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved,
        )
        let chunk = Int(format.sampleRate) * 10
        var position = range.lowerBound
        while position < range.upperBound {
            let end = min(position + chunk, range.upperBound)
            try output.write(from: read(input, range: position ..< end))
            position = end
        }
    }

    private static func read(_ file: AVAudioFile, range: Range<Int>) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(range.count)) else {
            throw AudioMixerError.bufferCreationFailed
        }
        file.framePosition = AVAudioFramePosition(range.lowerBound)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
        return buffer
    }
}
