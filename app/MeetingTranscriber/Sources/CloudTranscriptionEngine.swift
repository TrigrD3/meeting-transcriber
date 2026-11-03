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
    case httpError(status: Int, body: String)
    case invalidResponse
    /// The response carried no segment timestamps, which diarization needs.
    case missingSegments(model: String)

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            "Cloud transcription base URL is not valid: \"\(value)\""

        case let .httpError(status, body):
            "Cloud transcription failed with HTTP \(status)" + (body.isEmpty ? "" : ": \(body)")

        case .invalidResponse:
            "Cloud transcription returned a response that is not a transcription"

        case let .missingSegments(model):
            "Cloud model \"\(model)\" returned no segment timestamps. "
                + "Choose a model that supports response_format=verbose_json with segment timestamps, such as whisper-1."
        }
    }
}

/// Transcribes through an OpenAI-compatible `/audio/transcriptions` endpoint.
/// The whole 16 kHz WAV goes up in one request; diarization stays local.
@MainActor
final class CloudTranscriptionEngine: TranscribingEngine {
    /// Nothing to download or load: the model runs at the provider.
    let modelState: EngineModelState = .loaded
    let downloadProgress: Double = 0
    let transcriptionProgress: Double = 0

    private let configuration: @MainActor () -> CloudTranscriptionConfiguration
    private let session: URLSession
    /// Idle timeout between received bytes; an upload of a long recording can
    /// take minutes but keeps bytes moving.
    private let timeoutSeconds: TimeInterval

    init(
        configuration: @escaping @MainActor () -> CloudTranscriptionConfiguration,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 600,
    ) {
        self.configuration = configuration
        self.session = session
        self.timeoutSeconds = timeoutSeconds
    }

    func loadModel() async {} // swiftlint:disable:this async_without_await

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        let config = configuration()
        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmedBase), base.scheme != nil, base.host != nil else {
            throw CloudTranscriptionError.invalidBaseURL(trimmedBase)
        }
        let url = base.appendingPathComponent("audio").appendingPathComponent("transcriptions")

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
        // The refuser keeps a cross-origin 307/308 from replaying the recording
        // to a host the user did not configure.
        let (data, response) = try await session.upload(
            for: request, fromFile: bodyFile, delegate: CrossOriginRedirectRefuser(),
        )
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(bytes: data.prefix(500), encoding: .utf8) ?? ""
            throw CloudTranscriptionError.httpError(status: http.statusCode, body: body)
        }
        return try Self.parseSegments(data, model: config.model)
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
