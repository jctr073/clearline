import Foundation

/// Gemini API (generateContent) request and response mapping.
public enum GeminiWire {
    public static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    /// Model IDs become a URL path segment, so allow only the characters Gemini uses.
    public static func validatedModelID(_ model: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard !model.isEmpty, model.count <= 128, model.unicodeScalars.allSatisfy(allowed.contains) else { throw ProviderError.unsupportedModel }
        return model
    }

    public static func generateURL(model: String, stream: Bool) throws -> URL {
        let id = try validatedModelID(model)
        let method = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        return URL(string: "\(baseURL.absoluteString)/models/\(id):\(method)")!
    }

    public static func body(_ request: WritingRequest) throws -> Data {
        try WritingPrompt.validate(request)
        var generation: [String: Any] = [
            "maxOutputTokens": request.configuration.maxOutputTokens,
            "responseMimeType": "application/json",
            // responseJsonSchema accepts standard JSON Schema, including additionalProperties.
            "responseJsonSchema": OpenAIWire.schema
        ]
        if let effort = request.configuration.effort { generation["thinkingConfig"] = ["thinkingLevel": effort] }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": WritingPrompt.instructions(for: request)]]],
            "contents": [["role": "user", "parts": [["text": try WritingPrompt.input(for: request)]]]],
            "generationConfig": generation
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Visible answer text from one streamed candidate. Thought parts are never part of the proposal.
    public static func text(of candidate: [String: Any]) -> String {
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
    }

    /// Maps usageMetadata onto the shared ledger shape. Gemini reports thinking tokens
    /// separately from candidate tokens; the ledger counts them as output, like OpenAI does.
    public static func usage(_ object: Any?) -> TokenUsage? {
        guard let metadata = object as? [String: Any], let prompt = metadata["promptTokenCount"] as? Int else { return nil }
        let tool = metadata["toolUsePromptTokenCount"] as? Int ?? 0
        let candidates = metadata["candidatesTokenCount"] as? Int ?? 0
        let thoughts = metadata["thoughtsTokenCount"] as? Int
        var mapped: [String: Any] = ["input_tokens": prompt + tool, "output_tokens": candidates + (thoughts ?? 0)]
        if let cached = metadata["cachedContentTokenCount"] as? Int { mapped["input_tokens_details"] = ["cached_tokens": cached] }
        if let thoughts { mapped["output_tokens_details"] = ["reasoning_tokens": thoughts] }
        return TokenUsage.parse(mapped)
    }

    /// Gemini reports an invalid key as HTTP 400 with reason API_KEY_INVALID.
    /// Only the marker is inspected; the body never reaches the user.
    public static func error(status: Int, body: Data) -> ProviderError {
        if status == 400, String(decoding: body.prefix(65536), as: UTF8.self).contains("API_KEY_INVALID") { return .authentication }
        return ProviderError.http(status)
    }

    public static func modelIDs(fromListing data: Data) throws -> (ids: [String], next: String?) {
        struct List: Decodable {
            struct Model: Decodable { let name: String; let supportedGenerationMethods: [String]? }
            let models: [Model]?; let nextPageToken: String?
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        let ids = (list.models ?? []).filter { $0.supportedGenerationMethods?.contains("generateContent") == true }
            .map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst(7)) : $0.name }
            .filter { AIVendor.serving($0) == .gemini }
        return (ids, list.nextPageToken?.isEmpty == false ? list.nextPageToken : nil)
    }
}

public struct GeminiProvider: WritingProvider {
    private let key: String
    private let session: URLSession
    private let onUsage: @Sendable (String, TokenUsage) async -> Void
    public init(key: String, session: URLSession = .shared, onUsage: @escaping @Sendable (String, TokenUsage) async -> Void = { _, _ in }) {
        self.key = key; self.session = session; self.onUsage = onUsage
    }

    public func models() async throws -> [ModelCapability] {
        var ids: [String] = [], token: String?
        for _ in 0..<10 {
            var components = URLComponents(url: GeminiWire.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")] + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key"); request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw GeminiWire.error(status: status, body: data) }
            let page = try GeminiWire.modelIDs(fromListing: data)
            ids += page.ids
            guard let next = page.next else { break }
            token = next
        }
        return ModelCapability.available(ids)
    }

    public func perform(_ writing: WritingRequest, progress: @escaping @Sendable (Int) async -> Void) async throws -> WritingResult {
        let body = try GeminiWire.body(writing)
        let url = try GeminiWire.generateURL(model: writing.configuration.model, stream: true)
        let config = session.configuration
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = TimeInterval(writing.configuration.timeout)
        config.timeoutIntervalForResource = TimeInterval(writing.configuration.timeout)
        let streaming = URLSession(configuration: config)
        defer { streaming.invalidateAndCancel() }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            do {
                let (bytes, response) = try await streaming.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw ProviderError.offline }
                if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    if attempt < 2 {
                        let retry = min(8, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))))
                        try await Task.sleep(for: .seconds(retry)); continue
                    }
                }
                guard http.statusCode == 200 else {
                    var errorBody = Data()
                    for try await byte in bytes { errorBody.append(byte); if errorBody.count >= 65536 { break } }
                    throw GeminiWire.error(status: http.statusCode, body: errorBody)
                }
                var text = "", received = 0, model = writing.configuration.model
                var usage: TokenUsage?, finish: String?
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    received += line.utf8.count
                    guard received <= 3_000_000 else { throw ProviderError.malformed }
                    guard line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    // usageMetadata is cumulative; keep the latest report.
                    if let reported = GeminiWire.usage(event["usageMetadata"]) { usage = reported }
                    if let version = event["modelVersion"] as? String, !version.isEmpty { model = version }
                    if event["error"] != nil { finish = "ERROR"; break }
                    if (event["promptFeedback"] as? [String: Any])?["blockReason"] != nil { finish = "BLOCKED"; break }
                    guard let candidate = (event["candidates"] as? [[String: Any]])?.first else { continue }
                    let delta = GeminiWire.text(of: candidate)
                    if !delta.isEmpty { text += delta; await progress(text.count) }
                    if let reason = candidate["finishReason"] as? String { finish = reason; break }
                }
                // Record usage only for terminal responses, even when the proposal is unusable.
                if finish != nil, let usage { await onUsage(model, usage) }
                guard finish == "STOP" else { throw ProviderError.incomplete }
                return try OpenAIWire.parseResult(Data(text.utf8))
            } catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                if error.code == .timedOut { throw ProviderError.timeout }
                throw ProviderError.offline
            }
        }
        throw ProviderError.incomplete
    }
}
