import XCTest
@testable import ClearlineApp

final class AgentRuntimeTests: XCTestCase {
    private func makeRuntime() throws -> (root: URL, python: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let python = bin.appendingPathComponent("python3")
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        return (root, python)
    }

    func testAcceptsPrivateRuntimeOwnedByThisUser() throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        XCTAssertTrue(AgentRuntime.isTrusted(python: runtime.python.path))
    }

    func testRejectsWritableInterpreterOrDirectories() throws {
        for keyPath in [\(root: URL, python: URL).python, \.root] {
            let runtime = try makeRuntime()
            defer { try? FileManager.default.removeItem(at: runtime.root) }
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: runtime[keyPath: keyPath].path)
            XCTAssertFalse(AgentRuntime.isTrusted(python: runtime.python.path))
        }
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: runtime.python.deletingLastPathComponent().path)
        XCTAssertFalse(AgentRuntime.isTrusted(python: runtime.python.path))
    }

    func testRejectsAnotherOwnerAndMissingInterpreter() throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        XCTAssertFalse(AgentRuntime.isTrusted(python: runtime.python.path, uid: getuid() + 1))
        XCTAssertFalse(AgentRuntime.isTrusted(python: runtime.root.appendingPathComponent("bin/missing").path))
    }

    func testFollowsSymlinkToTheRealInterpreter() throws {
        let runtime = try makeRuntime(), target = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.root); try? FileManager.default.removeItem(at: target.root) }
        try FileManager.default.removeItem(at: runtime.python)
        try FileManager.default.createSymbolicLink(at: runtime.python, withDestinationURL: target.python)
        XCTAssertTrue(AgentRuntime.isTrusted(python: runtime.python.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: target.python.path)
        XCTAssertFalse(AgentRuntime.isTrusted(python: runtime.python.path))
    }
}
