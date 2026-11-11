import Foundation
import ClearlineCore

/// Optional SDK boundary: one child process per request, no listening port, no filesystem tools.
struct AgentProcessProvider: WritingProvider {
    let key: String
    var onUsage: @Sendable (String, TokenUsage) async -> Void = { _, _ in }
    func perform(_ request: WritingRequest, progress: @escaping @Sendable (Int) async -> Void) async throws -> WritingResult {
        let body = try OpenAIWire.body(request, stream: false)
        let payload: [String: Any] = ["api_key": key, "request": try JSONSerialization.jsonObject(with: body), "timeout": request.configuration.timeout]
        let input = try JSONSerialization.data(withJSONObject: payload)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var python = home.appendingPathComponent("Library/Application Support/Clearline/AgentRuntime/bin/python3").path
        #if DEBUG
        // Development only: a release build must not take its interpreter from the environment.
        if let override = ProcessInfo.processInfo.environment["CLEARLINE_AGENT_PYTHON"] { python = override }
        #endif
        let script = Bundle.main.resourceURL?.appendingPathComponent("agent-service/agent.py")
        guard FileManager.default.isExecutableFile(atPath: python), let script, FileManager.default.fileExists(atPath: script.path) else {
            throw ProviderError.service("Install the optional OpenAI Agents runtime using scripts/install-agent-runtime.sh, then relaunch. Or turn off the Agents SDK option to use the native Responses client.")
        }
        guard AgentRuntime.isTrusted(python: python) else {
            throw ProviderError.service("The OpenAI Agents runtime has unsafe ownership or permissions, so your key was not sent to it. Reinstall it using scripts/install-agent-runtime.sh, or turn off the Agents SDK option.")
        }
        let runner = ChildProcess()
        let data = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try runner.run(python: python, script: script.path, input: input) }.value
        } onCancel: { runner.cancel() }
        try Task.checkCancellation()
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.malformed }
        for report in envelope["usage"] as? [[String: Any]] ?? [] {
            if let usage = TokenUsage.parse(report["usage"]) {
                await onUsage(report["model"] as? String ?? request.configuration.model, usage)
            }
        }
        if let error = envelope["error"] as? String {
            switch error { case "authentication": throw ProviderError.authentication; case "rate_limit": throw ProviderError.rateLimit; case "timeout": throw ProviderError.timeout; case "connection": throw ProviderError.offline; default: throw ProviderError.service("The local OpenAI Agents runtime failed. Verify its installation and the selected model. Source text was not changed.") }
        }
        guard let result = envelope["result"] else { throw ProviderError.malformed }
        await progress(data.count)
        return try OpenAIWire.parseResult(JSONSerialization.data(withJSONObject: result))
    }
}

enum AgentRuntime {
    /// The interpreter receives the API key. Refuse one that another account could have
    /// replaced: the resolved binary, its bin directory, and the environment root must be
    /// owned by this user or root and not group- or world-writable. This cannot stop a
    /// process already running as this user.
    static func isTrusted(python: String, uid: uid_t = getuid()) -> Bool {
        let link = URL(fileURLWithPath: python)
        let bin = link.deletingLastPathComponent()
        return [link.resolvingSymlinksInPath().path, bin.path, bin.deletingLastPathComponent().path].allSatisfy { path in
            var info = stat()
            guard stat(path, &info) == 0 else { return false }
            return (info.st_uid == uid || info.st_uid == 0) && info.st_mode & (S_IWGRP | S_IWOTH) == 0
        }
    }
}

private final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; let active = process; lock.unlock(); if active?.isRunning == true { active?.terminate() } }
    func run(python: String, script: String, input: Data) throws -> Data {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: python); child.arguments = ["-I", script] // isolated: no PYTHON* variables, user site, or script directory on sys.path
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
