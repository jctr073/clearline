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
        XCTAssertThrowsError(try RequestConfiguration(model: "", effort: ""))
    }
    func testModelChangeNormalizesIncompatibleEffort() {
        XCTAssertEqual(ModelCapability.catalog[0].validatedEffort("high"), "")
        XCTAssertEqual(ModelCapability.catalog[2].validatedEffort("minimal"), "none")
    }
    func testAccountDiscoveryIncludesNewModelsAndDeduplicates() {
        let models = ModelCapability.available(["whisper-1", "gpt-4.1-mini", "future-text-model", "future-text-model", " "])
        XCTAssertEqual(models.map(\.id), ["future-text-model", "gpt-4.1-mini", "whisper-1"])
        XCTAssertFalse(models[0].hasKnownSettings)
        XCTAssertTrue(models[1].hasKnownSettings)
        XCTAssertEqual(models[0].validatedEffort("high"), "")
    }
    func testDiscoveredModelReachesWireWithAPIDefaultReasoning() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIWire.body(request(model: "future-text-model"))) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "future-text-model")
        XCTAssertNil(body["reasoning"])
        XCTAssertNotNil(body["text"])
        XCTAssertThrowsError(try request(model: "future-text-model", effort: "high"))
    }
    func testModelDiscoveryUsesLiveEndpointWithoutGenerating() async throws {
        FixtureProtocol.responseData = Data(#"{"data":[{"id":"future-text-model","owned_by":"openai"},{"id":"gpt-5.4"}]}"#.utf8)
        FixtureProtocol.status = 200; FixtureProtocol.requests = 0
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let provider = OpenAIProvider(key: "test-only", session: URLSession(configuration: configuration))
        let models = try await provider.models()
        XCTAssertEqual(models.map(\.id), ["future-text-model", "gpt-5.4"])
        XCTAssertEqual(models[1].efforts, ["none", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(FixtureProtocol.requests, 1)
        XCTAssertEqual(FixtureProtocol.lastRequest?.url?.path, "/v1/models")
        XCTAssertEqual(FixtureProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertNil(FixtureProtocol.lastRequest?.httpBody)
        XCTAssertEqual(FixtureProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }
    func testModelDiscoveryFailureDoesNotInventFallbackModels() async throws {
        FixtureProtocol.responseData = Data(); FixtureProtocol.status = 401
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let provider = OpenAIProvider(key: "test-only", session: URLSession(configuration: configuration))
        do { _ = try await provider.models(); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? ProviderError, .authentication) }
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
    func testTerminalUsageIsRecordedEvenWhenProposalIsInvalidOrIncomplete() async throws {
        for type in ["response.completed", "response.incomplete", "response.failed"] {
            let envelope: [String: Any] = ["type": type, "response": [
                "model": "actual-model-snapshot", "status": String(type.split(separator: ".").last!), "output": [],
                "usage": ["input_tokens": 100, "output_tokens": 40,
                          "input_tokens_details": ["cached_tokens": 30], "output_tokens_details": ["reasoning_tokens": 10]]
            ]]
            FixtureProtocol.responseData = Data(("data: " + String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)! + "\n\n").utf8)
            FixtureProtocol.status = 200
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
            let capture = UsageCapture()
            let provider = OpenAIProvider(key: "test-only", session: URLSession(configuration: configuration)) { model, usage in
                await capture.record(model: model, usage: usage)
            }
            do { _ = try await provider.perform(request()) { _ in }; XCTFail("No valid proposal") } catch {}
            let reports = await capture.reports
            XCTAssertEqual(reports.count, 1)
            XCTAssertEqual(reports.first?.0, "actual-model-snapshot")
            XCTAssertEqual(reports.first?.1.input_tokens, 100)
            XCTAssertEqual(reports.first?.1.output_tokens_details?.reasoning_tokens, 10)
        }
    }
    func testGeneratedTextCannotSupplyUsageAndMissingMetadataStaysUnknown() async throws {
        var proposal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        proposal["usage"] = ["input_tokens": 999, "output_tokens": 999]
        let output = String(data: try JSONSerialization.data(withJSONObject: proposal), encoding: .utf8)!
        let envelope: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": output]]]]]]
        FixtureProtocol.responseData = Data(("data: " + String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)! + "\n\n").utf8)
        FixtureProtocol.status = 200
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let capture = UsageCapture()
        let provider = OpenAIProvider(key: "test-only", session: URLSession(configuration: configuration)) { model, usage in
            await capture.record(model: model, usage: usage)
        }
        _ = try await provider.perform(request()) { _ in }
        let reports = await capture.reports
        XCTAssertTrue(reports.isEmpty)
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

private actor UsageCapture {
    var reports: [(String, TokenUsage)] = []
    func record(model: String, usage: TokenUsage) { reports.append((model, usage)) }
}

private final class FixtureProtocol: URLProtocol {
    static var responseData = Data()
    static var status = 200
    static var requests = 0
    static var failure: URLError?
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastRequest = request
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
