import XCTest
@testable import ClearlineCore

final class GeminiProviderTests: XCTestCase {
    private let result = #"{"text":"Write clearly.","explanation":"Removed unnecessary words.","tone":"Neutral","warnings":[],"recommendations":[],"edits":[]}"#
    override func setUp() { GeminiFixture.reset() }

    func request(model: String = "gemini-4-hydrogen", effort: String = "high") throws -> WritingRequest {
        WritingRequest(action: .clarity, text: "In order to write clearly.", instructions: "", preferences: .init(), configuration: try RequestConfiguration(model: model, effort: effort))
    }
    func provider(onUsage: @escaping @Sendable (String, TokenUsage) async -> Void = { _, _ in }) -> GeminiProvider {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GeminiFixture.self]
        return GeminiProvider(key: "test-only-not-a-real-key", session: URLSession(configuration: configuration), onUsage: onUsage)
    }
    func sse(_ events: [[String: Any]]) throws -> Data {
        Data(try events.map { "data: " + String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\r\n\r\n" }.joined().utf8)
    }
    func chunk(_ text: String, finish: String? = nil, thought: Bool = false, usage: [String: Any]? = nil) -> [String: Any] {
        var candidate: [String: Any] = ["content": ["role": "model", "parts": [thought ? ["text": text, "thought": true] : ["text": text]]], "index": 0]
        if let finish { candidate["finishReason"] = finish }
        var event: [String: Any] = ["candidates": [candidate], "modelVersion": "gemini-4-hydrogen-001"]
        if let usage { event["usageMetadata"] = usage }
        return event
    }

    // MARK: Vendor and catalog

    func testVendorIsDerivedFromModelID() {
        XCTAssertEqual(AIVendor.serving("gemini-4-neon"), .gemini)
        XCTAssertEqual(AIVendor.serving("gemma-4-31b-it"), .gemini)
        XCTAssertEqual(AIVendor.serving("gpt-5.6-terra"), .openAI)
        XCTAssertEqual(AIVendor.serving("future-text-model"), .openAI)
        XCTAssertEqual(ModelCapability.capability(for: "gemini-3.8-flash").vendor, .gemini)
    }
    func testWritingPickerListsBothVendorsWithDisplayNames() {
        let discovered = ModelCapability.available(["gpt-5.6-terra", "gemini-4-hydrogen", "gemini-3.8-flash", "gemini-2.5-flash", "gemini-3.8-flash-tts"])
        let models = ModelCapability.writingModels(from: discovered)
        XCTAssertEqual(models.map(\.id), ["gpt-5.6-terra", "gemini-4-hydrogen", "gemini-3.8-flash"])
        XCTAssertEqual(models.map(\.displayName), ["GPT-5.6 Terra", "Gemini 4 Hydrogen", "Gemini 3.8 Flash"])
        XCTAssertEqual(ModelCapability.capability(for: "gemini-2.5-flash").displayName, "gemini-2.5-flash")
    }
    func testThinkingLevelsMatchEachModel() {
        // Verified against the live API: argon and 3.8 Flash reject XHIGH with HTTP 400.
        XCTAssertEqual(ModelCapability.capability(for: "gemini-4-hydrogen").efforts, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(ModelCapability.capability(for: "gemini-4-neon").efforts, ["low", "medium", "high", "xhigh"])
        for model in ["gemini-4-carbon", "gemini-4-argon", "gemini-3.8-flash"] {
            XCTAssertEqual(ModelCapability.capability(for: model).efforts, ["low", "medium", "high"])
            XCTAssertThrowsError(try request(model: model, effort: "xhigh"))
        }
        XCTAssertThrowsError(try request(model: "gemini-4-hydrogen", effort: "none"))
        XCTAssertThrowsError(try request(model: "gemini-4-hydrogen", effort: ""))
        XCTAssertEqual(ModelCapability.capability(for: "gemini-4-hydrogen").validatedEffort("max"), "high")
    }
    func testErrorMessagesNameTheVendor() {
        XCTAssertEqual(ProviderError.authentication.description(for: .gemini), "Gemini rejected this key. Update it in Settings.")
        XCTAssertEqual(ProviderError.authentication.errorDescription, "OpenAI rejected this key. Update it in Settings.")
        XCTAssertEqual(ProviderError.message(for: ProviderError.server(500), vendor: .gemini), "Gemini request failed (HTTP 500). Your source text was not changed.")
    }

    // MARK: Wire format

    func testBodyUsesStructuredOutputAndThinkingLevel() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: GeminiWire.body(request(effort: "xhigh"))) as? [String: Any])
        let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseMimeType"] as? String, "application/json")
        XCTAssertEqual((generation["responseJsonSchema"] as? [String: Any])?["required"] as? [String], ["text", "explanation", "tone", "warnings", "recommendations", "edits"])
        XCTAssertEqual((generation["thinkingConfig"] as? [String: String])?["thinkingLevel"], "xhigh")
        XCTAssertEqual(generation["maxOutputTokens"] as? Int, 4096)
        let system = try XCTUnwrap(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]])?.first?["text"])
        XCTAssertTrue(system.contains("untrusted data"))
        let user = try XCTUnwrap((body["contents"] as? [[String: Any]])?.first)
        XCTAssertEqual(user["role"] as? String, "user")
        let input = try XCTUnwrap((user["parts"] as? [[String: String]])?.first?["text"])
        XCTAssertTrue(input.contains("In order to write clearly."))
        XCTAssertNil(body["model"]); XCTAssertNil(body["reasoning"]); XCTAssertNil(body["store"])
    }
    func testUncataloguedModelOmitsThinkingConfig() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: GeminiWire.body(request(model: "gemini-9-future", effort: ""))) as? [String: Any])
        XCTAssertNil((body["generationConfig"] as? [String: Any])?["thinkingConfig"])
    }
    func testGeminiAndOpenAIShareThePrompt() throws {
        let gemini = try XCTUnwrap(JSONSerialization.jsonObject(with: GeminiWire.body(request())) as? [String: Any])
        let openAI = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIWire.body(request(model: "gpt-5.5", effort: "low"))) as? [String: Any])
        let system = ((gemini["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]])?.first?["text"]
        XCTAssertEqual(system, openAI["instructions"] as? String)
    }
    func testPayloadLimitApplies() throws {
        var prefs = WritingPreferences(); prefs.maxInputCharacters = 10
        let req = WritingRequest(action: .draft, text: "abc", instructions: "1234567890", preferences: prefs, configuration: try RequestConfiguration(model: "gemini-4-argon", effort: "low"))
        XCTAssertThrowsError(try GeminiWire.body(req)) { XCTAssertEqual($0 as? ProviderError, .tooLarge) }
    }
    func testModelIDCannotEscapeTheURLPath() {
        XCTAssertEqual(try GeminiWire.generateURL(model: "gemini-4-neon", stream: true).absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-neon:streamGenerateContent?alt=sse")
        for bad in ["gemini-4/../../x", "gemini 4", "gemini-4?key=x", "Gemini-4", ""] {
            XCTAssertThrowsError(try GeminiWire.generateURL(model: bad, stream: true))
        }
    }
    func testUsageCountsThinkingAsOutput() throws {
        let usage = try XCTUnwrap(GeminiWire.usage(["promptTokenCount": 248, "candidatesTokenCount": 38, "thoughtsTokenCount": 66, "cachedContentTokenCount": 100, "totalTokenCount": 352]))
        XCTAssertEqual(usage.input_tokens, 248); XCTAssertEqual(usage.output_tokens, 104)
        XCTAssertEqual(usage.output_tokens_details?.reasoning_tokens, 66)
        XCTAssertEqual(usage.input_tokens_details?.cached_tokens, 100)
        let plain = try XCTUnwrap(GeminiWire.usage(["promptTokenCount": 10, "candidatesTokenCount": 5]))
        XCTAssertNil(plain.output_tokens_details); XCTAssertNil(plain.input_tokens_details)
        XCTAssertNil(GeminiWire.usage(["candidatesTokenCount": 5]))
        XCTAssertNil(GeminiWire.usage(["promptTokenCount": 10, "candidatesTokenCount": 5, "cachedContentTokenCount": 50]))
    }
    func testHTTPErrorsMapWithoutLeakingBodies() {
        let invalidKey = Data(#"{"error":{"code":400,"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8)
        XCTAssertEqual(GeminiWire.error(status: 400, body: invalidKey), .authentication)
        XCTAssertEqual(GeminiWire.error(status: 400, body: Data(#"{"error":{"message":"Thinking level XHIGH is not supported"}}"#.utf8)), .server(400))
        XCTAssertEqual(GeminiWire.error(status: 403, body: Data()), .authentication)
        XCTAssertEqual(GeminiWire.error(status: 404, body: Data()), .unavailableModel)
        XCTAssertEqual(GeminiWire.error(status: 429, body: Data()), .rateLimit)
    }

    // MARK: Transport

    func testModelDiscoveryFiltersAndFollowsPages() async throws {
        GeminiFixture.responses = [
            (200, Data(#"{"models":[{"name":"models/gemini-4-hydrogen","supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/text-embedding-005","supportedGenerationMethods":["embedContent"]},{"name":"models/lyria-3.5","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"page-2"}"#.utf8)),
            (200, Data(#"{"models":[{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-4-hydrogen","supportedGenerationMethods":["generateContent"]}]}"#.utf8))
        ]
        let models = try await provider().models()
        XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash", "gemini-4-hydrogen"])
        XCTAssertEqual(GeminiFixture.seen.count, 2)
        let first = try XCTUnwrap(GeminiFixture.seen.first)
        XCTAssertEqual(first.url?.path, "/v1beta/models"); XCTAssertEqual(first.httpMethod, "GET")
        XCTAssertEqual(first.value(forHTTPHeaderField: "x-goog-api-key"), "test-only-not-a-real-key")
        XCTAssertFalse(first.url!.absoluteString.contains("test-only"), "The key must never appear in the URL")
        XCTAssertTrue(GeminiFixture.seen[1].url!.absoluteString.contains("pageToken=page-2"))
    }
    func testModelDiscoveryRejectsInvalidKey() async throws {
        GeminiFixture.responses = [(400, Data(#"{"error":{"details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8))]
        do { _ = try await provider().models(); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? ProviderError, .authentication) }
    }
    func testStreamingJoinsChunksSkipsThoughtsAndRecordsUsageOnce() async throws {
        let half = result.index(result.startIndex, offsetBy: 20)
        let usage: [String: Any] = ["promptTokenCount": 200, "candidatesTokenCount": 30, "thoughtsTokenCount": 12]
        GeminiFixture.responses = [(200, try sse([
            chunk("Planning the rewrite…", thought: true, usage: ["promptTokenCount": 200, "candidatesTokenCount": 0]),
            chunk(String(result[..<half]), usage: ["promptTokenCount": 200, "candidatesTokenCount": 10]),
            chunk(String(result[half...]), usage: usage),
            chunk("", finish: "STOP", usage: usage)
        ]))]
        let capture = GeminiUsageCapture(), progress = GeminiUsageCapture()
        let output = try await provider { await capture.record(model: $0, usage: $1) }.perform(request()) { await progress.count($0) }
        XCTAssertEqual(output.text, "Write clearly.")
        let reports = await capture.reports
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0, "gemini-4-hydrogen-001")
        XCTAssertEqual(reports.first?.1.output_tokens, 42)
        let counts = await progress.counts
        XCTAssertEqual(counts.last, result.count)
        let sent = try XCTUnwrap(GeminiFixture.seen.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-hydrogen:streamGenerateContent?alt=sse")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-goog-api-key"), "test-only-not-a-real-key")
    }
    func testNonStopFinishIsIncompleteButUsageIsRecorded() async throws {
        for terminal in [chunk(String(result.prefix(10)), finish: "MAX_TOKENS", usage: ["promptTokenCount": 5, "candidatesTokenCount": 4096]),
                         ["promptFeedback": ["blockReason": "SAFETY"], "usageMetadata": ["promptTokenCount": 5]] as [String: Any]] {
            GeminiFixture.reset()
            GeminiFixture.responses = [(200, try sse([terminal]))]
            let capture = GeminiUsageCapture()
            do { _ = try await provider { await capture.record(model: $0, usage: $1) }.perform(request()) { _ in }; XCTFail("Must be incomplete") }
            catch { XCTAssertEqual(error as? ProviderError, .incomplete) }
            let reports = await capture.reports
            XCTAssertEqual(reports.count, 1)
        }
    }
    func testInterruptedStreamReturnsNothingAndRecordsNoUsage() async throws {
        GeminiFixture.responses = [(200, try sse([chunk(String(result.prefix(10)), usage: ["promptTokenCount": 5, "candidatesTokenCount": 3])]))]
        let capture = GeminiUsageCapture()
        do { _ = try await provider { await capture.record(model: $0, usage: $1) }.perform(request()) { _ in }; XCTFail("Must reject") }
        catch { XCTAssertEqual(error as? ProviderError, .incomplete) }
        let reports = await capture.reports
        XCTAssertTrue(reports.isEmpty)
    }
    func testMalformedProposalIsRejected() async throws {
        GeminiFixture.responses = [(200, try sse([chunk("not JSON", finish: "STOP")]))]
        do { _ = try await provider().perform(request()) { _ in }; XCTFail("Must reject") }
        catch { XCTAssertEqual(error as? ProviderError, .malformed) }
    }
    func testInvalidKeyDuringGenerationIsAuthentication() async throws {
        GeminiFixture.responses = [(400, Data(#"{"error":{"details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8))]
        do { _ = try await provider().perform(request()) { _ in }; XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? ProviderError, .authentication) }
        XCTAssertEqual(GeminiFixture.seen.count, 1, "Client errors are not retried")
    }
    func testServerErrorsStopAfterThreeAttempts() async throws {
        GeminiFixture.responses = [(503, Data())]
        do { _ = try await provider().perform(request()) { _ in }; XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? ProviderError, .server(503)) }
        XCTAssertEqual(GeminiFixture.seen.count, 3)
    }
}

private actor GeminiUsageCapture {
    var reports: [(String, TokenUsage)] = []
    var counts: [Int] = []
    func record(model: String, usage: TokenUsage) { reports.append((model, usage)) }
    func count(_ value: Int) { counts.append(value) }
}

/// Serves queued responses in order; the last one repeats.
private final class GeminiFixture: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static func reset() { responses = []; seen = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = min(Self.seen.count, max(0, Self.responses.count - 1))
        Self.seen.append(request)
        let (status, data) = Self.responses.isEmpty ? (500, Data()) : Self.responses[index]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
