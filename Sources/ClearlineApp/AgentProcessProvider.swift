import Foundation
import ClearlineCore

/// Optional SDK boundary: one child process per request, no listening port, no filesystem tools.
struct AgentProcessProvider: WritingProvider {
    let key: String
    func perform(_ request: WritingRequest, progress: @escaping @Sendable (Int) async -> Void) async throws -> WritingResult {
        let body = try OpenAIWire.body(request, stream: false)
        let payload: [String: Any] = ["api_key": key, "request": try JSONSerialization.jsonObject(with: body), "timeout": request.configuration.timeout]
        let input = try JSONSerialization.data(withJSONObject: payload)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let python = ProcessInfo.processInfo.environment["CLEARLINE_AGENT_PYTHON"] ?? home.appendingPathComponent("Library/Application Support/Clearline/AgentRuntime/bin/python3").path
        let script = Bundle.main.resourceURL?.appendingPathComponent("agent-service/agent.py")
        guard FileManager.default.isExecutableFile(atPath: python), let script, FileManager.default.fileExists(atPath: script.path) else {
            throw ProviderError.service("Install the optional OpenAI Agents runtime using scripts/install-agent-runtime.sh, then relaunch. Or turn off the Agents SDK option to use the native Responses client.")
        }
        let runner = ChildProcess()
        let data = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try runner.run(python: python, script: script.path, input: input) }.value
        } onCancel: { runner.cancel() }
        try Task.checkCancellation()
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.malformed }
        if let error = envelope["error"] as? String {
            switch error { case "authentication": throw ProviderError.authentication; case "rate_limit": throw ProviderError.rateLimit; case "timeout": throw ProviderError.timeout; case "connection": throw ProviderError.offline; default: throw ProviderError.service("The local OpenAI Agents runtime failed. Verify its installation and the selected model. Source text was not changed.") }
        }
        guard let result = envelope["result"] else { throw ProviderError.malformed }
        await progress(data.count)
        return try OpenAIWire.parseResult(JSONSerialization.data(withJSONObject: result))
    }
}

private final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; let active = process; lock.unlock(); if active?.isRunning == true { active?.terminate() } }
    func run(python: String, script: String, input: Data) throws -> Data {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: python); child.arguments = [script]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run(); lock.unlock() } catch { lock.unlock(); throw error }
        try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0, data.count <= 2_000_000 else { throw ProviderError.service("The OpenAI Agents runtime could not complete this request. Verify the Python environment; no source text was changed.") }
        return data
    }
}
