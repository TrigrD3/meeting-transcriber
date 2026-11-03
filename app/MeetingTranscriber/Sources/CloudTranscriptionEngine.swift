import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CloudTranscriptionEngine")

/// Where and how a recording is sent for cloud transcription. Read when a
/// track is transcribed, not when the job is queued: only the choice of
/// cloud over local is captured per job.
struct CloudTranscriptionConfiguration: Equatable {
    /// OpenAI-compatible API base, e.g. `https://api.openai.com/v1`.
    var baseURL: String
    var model: String
    /// Sent as a Bearer token; empty sends no `Authorization` header.
    var apiKey: String
}

enum CloudTranscriptionError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    /// `body` is the provider's own error message when it sent one, else the
    /// first 500 characters of the response, with the API key redacted.
    case httpError(status: Int, body: String)
    /// The request did not complete; carries the transport's description.
    case network(String)
    case invalidResponse
    /// The response carried no segment timestamps, which diarization needs.
    case missingSegments(model: String)

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            "Cloud transcription base URL is not valid: \"\(value)\""

        case let .httpError(status, body):
            "Cloud transcription failed: \(Self.reason(status: status)) (HTTP \(status))"
                + (body.isEmpty ? "" : ": \(body)")

        case let .network(description):
            "Cloud transcription failed: the provider could not be reached (\(description))"

        case .invalidResponse:
            "Cloud transcription returned a response that is not a transcription"

        case let .missingSegments(model):
            "Cloud model \"\(model)\" returned no segment timestamps. "
                + "Choose a model that supports response_format=verbose_json with segment timestamps, such as whisper-1."
        }
    }

    private static func reason(status: Int) -> String {
        switch status {
        case 401, 403: "the API key was rejected"
        case 400: "the provider could not process this audio"
        case 413: "the recording is too large for the provider"
        case 429: "the provider is rate limiting requests or the quota is used up"
        case 500 ... 599: "the provider had a server error"
        default: "the provider refused the request"
        }
    }
}

/// Transcribes through an OpenAI-compatible `/audio/transcriptions` endpoint.
/// A recording up to `pieceDuration` goes up in one request; a longer one is
/// cut into pieces (`CloudAudioSplitter`) sent one after another. Diarization
/// stays local.
@MainActor
final class CloudTranscriptionEngine: TranscribingEngine {
    /// Nothing to download or load: the model runs at the provider.
    let modelState: EngineModelState = .loaded
    let downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0

    private let configuration: @MainActor () -> CloudTranscriptionConfiguration
    private let session: URLSession
    /// Idle timeout between received bytes; an upload of a long recording can
    /// take minutes but keeps bytes moving.
    private let timeoutSeconds: TimeInterval
    /// Waits before each retry of a transient failure; its count is the
    /// number of retries per request.
    private let retryDelays: [Duration]
    /// Longest `Retry-After` honoured, so a provider cannot park a job for an hour.
    static let maxRetryAfter: Duration = .seconds(60)
    /// Injected so tests do not wait; throws on cancellation.
    private let sleep: @MainActor (Duration) async throws -> Void
    /// Longest piece sent in one request; injectable so tests use seconds.
    private let pieceDuration: TimeInterval
    /// How far before a piece boundary a quiet cut point is searched for.
    private let searchWindow: TimeInterval

    init(
        configuration: @escaping @MainActor () -> CloudTranscriptionConfiguration,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 600,
        retryDelays: [Duration] = [.seconds(2), .seconds(8)],
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pieceDuration: TimeInterval = CloudAudioSplitter.defaultPieceDuration,
        searchWindow: TimeInterval = CloudAudioSplitter.defaultSearchWindow,
    ) {
        self.configuration = configuration
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.pieceDuration = pieceDuration
        self.searchWindow = searchWindow
    }

    func loadModel() async {} // swiftlint:disable:this async_without_await

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        let config = configuration()
        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmedBase), base.scheme != nil, base.host != nil else {
            throw CloudTranscriptionError.invalidBaseURL(trimmedBase)
        }
        let url = base.appendingPathComponent("audio").appendingPathComponent("transcriptions")

        transcriptionProgress = 0
        // A file AVAudioFile cannot read goes up whole, so the provider's
        // verdict (a 400, the track's own failure) decides as before.
        guard let (pieces, sampleRate) = try? CloudAudioSplitter.planPieces(
            of: audioPath, pieceDuration: pieceDuration, searchWindow: searchWindow,
        ), pieces.count > 1 else {
            let segments = try await transcribeFile(audioPath, url: url, config: config)
            transcriptionProgress = 1
            return segments
        }

        logger.info("cloud_transcription_split pieces=\(pieces.count)")
        let stem = audioPath.deletingPathExtension().lastPathComponent
        var result: [TimestampedSegment] = []
        for (index, range) in pieces.enumerated() {
            let pieceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(stem)_part\(index + 1)_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: pieceURL) }
            try CloudAudioSplitter.writePiece(of: audioPath, range: range, to: pieceURL)
            let offset = Double(range.lowerBound) / sampleRate
            for segment in try await transcribeFile(pieceURL, url: url, config: config) {
                var shifted = segment
                shifted.start += offset
                shifted.end += offset
                result.append(shifted)
            }
            transcriptionProgress = Double(index + 1) / Double(pieces.count)
        }
        return result
    }

    /// One file in one request, through the retry loop.
    private func transcribeFile(
        _ audioPath: URL, url: URL, config: CloudTranscriptionConfiguration,
    ) async throws -> [TimestampedSegment] {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud_transcription_\(UUID().uuidString).multipart")
        try Self.writeMultipartBody(to: bodyFile, boundary: boundary, audioPath: audioPath, model: config.model)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        logger.info("cloud_transcription_upload host=\(url.host ?? "?", privacy: .public) model=\(config.model, privacy: .public)")
        var attempt = 0
        while true {
            try Task.checkCancellation()
            switch try await send(request, bodyFile: bodyFile, config: config) {
            case let .done(segments):
                return segments

            case let .transient(error, retryAfter):
                guard attempt < retryDelays.count else { throw error }
                let delay = min(retryAfter ?? retryDelays[attempt], Self.maxRetryAfter)
                attempt += 1
                logger.warning(
                    "cloud_transcription_retry attempt=\(attempt) delay=\(delay, privacy: .public) error=\(error.localizedDescription, privacy: .public)",
                )
                try await sleep(delay)
            }
        }
    }

    private enum Attempt {
        case done([TimestampedSegment])
        /// Worth another try: a dropped connection, a 429 or a 5xx.
        case transient(CloudTranscriptionError, retryAfter: Duration?)
    }

    /// Transport failures worth retrying; anything else (a bad certificate,
    /// an unsupported URL) fails the same way the next time.
    private static let transientCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// One request. Throws what retrying cannot fix: auth, a rejected file,
    /// any other 4xx, an unreadable answer.
    private func send(_ request: URLRequest, bodyFile: URL, config: CloudTranscriptionConfiguration) async throws -> Attempt {
        let data: Data
        let response: URLResponse
        do {
            // The refuser keeps a cross-origin 307/308 from replaying the recording
            // to a host the user did not configure.
            (data, response) = try await session.upload(
                for: request, fromFile: bodyFile, delegate: CrossOriginRedirectRefuser(),
            )
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            let failure = CloudTranscriptionError.network(error.localizedDescription)
            guard Self.transientCodes.contains(error.code) else { throw failure }
            return .transient(failure, retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let failure = CloudTranscriptionError.httpError(
                status: http.statusCode, body: Self.errorMessage(data, redacting: config.apiKey),
            )
            guard http.statusCode == 429 || (500 ... 599).contains(http.statusCode) else { throw failure }
            return .transient(failure, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        return try .done(Self.parseSegments(data, model: config.model))
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// The provider's `{"error":{"message":…}}` when present, else the first
    /// 500 characters of the body. Some providers echo the key back; it is cut.
    static func errorMessage(_ data: Data, redacting apiKey: String) -> String {
        let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            ?? String(bytes: data.prefix(500), encoding: .utf8) ?? ""
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return apiKey.isEmpty ? trimmed : trimmed.replacingOccurrences(of: apiKey, with: "[redacted]")
    }

    /// `Retry-After` as delta-seconds or an HTTP-date; nil when absent or unreadable.
    static func retryAfter(_ value: String?, now: Date = Date()) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return .seconds(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
    }

    /// Streams the multipart body to disk so a long recording is never held
    /// in memory twice.
    static func writeMultipartBody(to destination: URL, boundary: String, audioPath: URL, model: String) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        func field(_ name: String, _ value: String) -> Data {
            Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        try out.write(contentsOf: field("model", model))
        try out.write(contentsOf: field("response_format", "verbose_json"))
        try out.write(contentsOf: field("timestamp_granularities[]", "segment"))
        try out.write(contentsOf: Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioPath.lastPathComponent)\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n"
        ).utf8))

        let input = try FileHandle(forReadingFrom: audioPath)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private struct VerboseResponse: Decodable {
        struct Segment: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
        }

        /// Nil, not empty, is the "no timestamps" answer of a plain-JSON model.
        let segments: [Segment]? // swiftlint:disable:this discouraged_optional_collection
    }

    static func parseSegments(_ data: Data, model: String) throws -> [TimestampedSegment] {
        let decoded: VerboseResponse
        do {
            decoded = try JSONDecoder().decode(VerboseResponse.self, from: data)
        } catch {
            throw CloudTranscriptionError.invalidResponse
        }
        guard let segments = decoded.segments else {
            throw CloudTranscriptionError.missingSegments(model: model)
        }
        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimestampedSegment(start: segment.start, end: segment.end, text: text)
        }
    }
}
