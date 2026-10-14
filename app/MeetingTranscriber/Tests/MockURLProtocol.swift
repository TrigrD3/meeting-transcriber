import Foundation

/// Test URL-loading shim: route a `URLSession` through this (set
/// `configuration.protocolClasses = [MockURLProtocol.self]`) and drive responses
/// via the static handlers. Set the relevant handler before the request and
/// clear all of them in tearDown.
final class MockURLProtocol: URLProtocol {
    // URLSession serialises protocol callbacks per task; the handler is set
    // before the request is started and cleared in tearDown. No real race.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    // When set, the request fails at the transport layer with this error
    // (mirrors a connection refused / DNS failure / dropped socket). Takes
    // precedence over `handler` so the generator's catch path is exercised.
    nonisolated(unsafe) static var errorHandler: ((URLRequest) -> any Error)?
    // When set, delivers a NON-HTTP `URLResponse` (takes precedence over
    // `handler`) so the generator's `response as? HTTPURLResponse` guard fails.
    nonisolated(unsafe) static var rawResponseHandler: ((URLRequest) -> (URLResponse, Data))?
    // When set, delivers the response + data but NEVER finishes loading —
    // simulates a stream that trickles/stalls forever (the struggling-LLM case),
    // so the generator's total-deadline can be exercised.
    nonisolated(unsafe) static var hangHandler: ((URLRequest) -> (HTTPURLResponse, Data))?
    // When set and it returns a status + location for a request, that request
    // is answered with a redirect instead of reaching `handler`. The follow-up
    // request carries every header of the original, as URLSession's HTTP
    // loader replays them, so only the session's redirect delegate can drop one.
    // The real loader drops `Authorization` itself on a redirect, so this hook
    // cannot stand in for the Bearer path.
    nonisolated(unsafe) static var redirectHandler: ((URLRequest) -> (status: Int, location: URL)?)?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let (status, location) = Self.redirectHandler?(request) {
            redirect(to: location, status: status)
            return
        }
        if let errorHandler = Self.errorHandler {
            client?.urlProtocol(self, didFailWithError: errorHandler(request))
            return
        }
        if let rawResponseHandler = Self.rawResponseHandler {
            let (response, data) = rawResponseHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if let hangHandler = Self.hangHandler {
            let (response, data) = hangHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            // Intentionally never finish — the stream stalls; only a total
            // deadline (not the idle timeout) can end this.
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func redirect(to location: URL, status: Int) {
        guard let response = HTTPURLResponse(
            url: request.url ?? location,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": location.absoluteString],
        ) else { return }
        var followUp = request
        followUp.url = location
        client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
        // A followed redirect stops this load and ignores the rest. A refused
        // one makes the 3xx the final response, as the HTTP loader does, so it
        // is delivered here.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
