import XCTest
@testable import ClearlineCore

final class ProviderTests: XCTestCase {
    private let result = #"{"text":"Write clearly.","explanation":"Removed unnecessary words.","tone":"Neutral","warnings":[],"recommendations":[],"edits":[]}"#
    func request(model: String = "gpt-4.1-mini", effort: String = "") throws -> WritingRequest {
        WritingRequest(action: .clarity, text: "In order to write clearly.", instructions: "", preferences: .init(), configuration: try RequestConfiguration(model: model, effort: effort))
    }
    func testNonReasoningModelsOmitReasoningOnWire() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIWire.body(request())) as? [String: Any])
        XCTAssertNil(body["reasoning"]); XCTAssertEqual(body["model"] as? String, "gpt-4.1-mini"); XCTAssertEqual(body["store"] as? Bool, false)
    }
    func testReasoningSelectionReachesActualRequest() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIWire.body(request(model: "gpt-5.4", effort: "high"))) as? [String: Any])
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "high")
    }
    func testUnsupportedEffortAndModelsRejected() {
        XCTAssertThrowsError(try RequestConfiguration(model: "gpt-4.1-mini", effort: "high"))
        XCTAssertThrowsError(try RequestConfiguration(model: "gpt-5.4", effort: "minimal"))
        XCTAssertThrowsError(try RequestConfiguration(model: "unknown", effort: ""))
    }
    func testModelChangeNormalizesIncompatibleEffort() {
        XCTAssertEqual(ModelCapability.catalog[0].validatedEffort("high"), "")
        XCTAssertEqual(ModelCapability.catalog[2].validatedEffort("minimal"), "none")
    }
    func testAccountModelsAreFiltered() {
        XCTAssertEqual(ModelCapability.available(["whisper-1", "gpt-4.1-mini", "unknown"]).map(\.id), ["gpt-4.1-mini"])
    }
    func testStructuredCompletedResponse() throws {
        let response: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": result]]]]]
        XCTAssertEqual(try OpenAIWire.parseResponse(JSONSerialization.data(withJSONObject: response)).text, "Write clearly.")
    }
    func testRefusalIncompleteAndMalformedRejected() {
        for response in [#"{"status":"incomplete","output":[]}"#, #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#, #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"not JSON"}]}]}"#] {
            XCTAssertThrowsError(try OpenAIWire.parseResponse(Data(response.utf8)))
        }
    }
    func testInvalidAIRangesRejectedAsAWhole() throws {
        let raw = #"{"text":"hello","explanation":"","tone":"","warnings":[],"recommendations":[],"edits":[{"location":9,"length":3,"original":"bad","replacement":"good","category":"Clarity","explanation":"test"}]}"#
        let result = try OpenAIWire.parseResult(Data(raw.utf8))
        XCTAssertThrowsError(try result.suggestions(for: WritingDocument(text: "hello")))
    }
    func testPayloadLimitIncludesFollowupAndInstructions() throws {
        var prefs = WritingPreferences(); prefs.maxInputCharacters = 10
        let req = WritingRequest(action: .draft, text: "abc", instructions: "1234567890", preferences: prefs, configuration: try RequestConfiguration(model: "gpt-4.1-mini", effort: ""))
        XCTAssertThrowsError(try OpenAIWire.body(req)) { XCTAssertEqual($0 as? ProviderError, .tooLarge) }
    }
    func testFailureMessagesDoNotLeakResponseBodies() {
        XCTAssertEqual(ProviderError.http(401), .authentication); XCTAssertEqual(ProviderError.http(429), .rateLimit)
        XCTAssertEqual(ProviderError.http(404), .unavailableModel); XCTAssertEqual(ProviderError.http(503), .server(503))
    }
    func testLiveStreamingTransportWithDeterministicFixture() async throws {
        let envelope: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": result]]]]]]
        let event = "data: " + String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)! + "\n\n"
        FixtureProtocol.responseData = Data(event.utf8); FixtureProtocol.status = 200
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let provider = OpenAIProvider(key: "test-only-not-a-real-key", session: URLSession(configuration: configuration))
        let output = try await provider.perform(request()) { _ in }
        XCTAssertEqual(output.text, "Write clearly.")
    }
    func testAuthenticationFailureDoesNotReturnProposal() async throws {
        FixtureProtocol.responseData = Data(); FixtureProtocol.status = 401
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let provider = OpenAIProvider(key: "test-only-not-a-real-key", session: URLSession(configuration: configuration))
        do { _ = try await provider.perform(request()) { _ in }; XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? ProviderError, .authentication) }
    }
    func testCancellationBeforeRequest() async throws {
        let req = try request()
        let task = Task { try await OpenAIProvider(key: "test-only").perform(req) { _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testTransientErrorsStopAfterThreeAttempts() async throws {
        FixtureProtocol.responseData = Data(); FixtureProtocol.status = 503; FixtureProtocol.requests = 0
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let provider = OpenAIProvider(key: "test-only", session: URLSession(configuration: configuration))
        do { _ = try await provider.perform(request()) { _ in }; XCTFail("Must fail after bounded retries") }
        catch { XCTAssertEqual(error as? ProviderError, .server(503)) }
        XCTAssertEqual(FixtureProtocol.requests, 3)
    }
    func testTimeoutIsReportedWithoutAProposal() async throws {
        FixtureProtocol.failure = URLError(.timedOut)
        defer { FixtureProtocol.failure = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let provider = OpenAIProvider(key: "test-only", session: URLSession(configuration: configuration))
        do { _ = try await provider.perform(request()) { _ in }; XCTFail("Must time out") }
        catch { XCTAssertEqual(error as? ProviderError, .timeout) }
    }
    func testInterruptedStreamDoesNotReturnPartialProposal() async throws {
        FixtureProtocol.status = 200; FixtureProtocol.responseData = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let provider = OpenAIProvider(key: "test-only", session: URLSession(configuration: configuration))
        do { _ = try await provider.perform(request()) { _ in }; XCTFail("Must reject incomplete stream") }
        catch { XCTAssertEqual(error as? ProviderError, .incomplete) }
    }
}

private final class FixtureProtocol: URLProtocol {
    static var responseData = Data()
    static var status = 200
    static var requests = 0
    static var failure: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
