import XCTest
@testable import ClearlineApp

final class ApplicationLookupTests: XCTestCase {
    private func makeApp(in root: URL, name: String, metadata: [String: String]) throws -> URL {
        let url = root.appendingPathComponent(name + ".app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    func testReadsDisplayNameAndIdentifierWithoutAnExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp(in: root, name: "Different Filename", metadata: [
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.example.editor",
            "CFBundleDisplayName": "Friendly Editor", "CFBundleName": "InternalName"
        ])
        let app = try InstalledApplication(url: url)
        XCTAssertEqual(app.id, "com.example.editor")
        XCTAssertEqual(app.name, "Friendly Editor")
        XCTAssertEqual(app.url, url)
    }

    func testFallsBackToBundleNameThenFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let named = try makeApp(in: root, name: "Named", metadata: [
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.example.named",
            "CFBundleDisplayName": " ", "CFBundleName": "Editor"
        ])
        XCTAssertEqual(try InstalledApplication(url: named).name, "Editor")
        let unnamed = try makeApp(in: root, name: "Filename Editor", metadata: [
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.example.unnamed"
        ])
        XCTAssertEqual(try InstalledApplication(url: unnamed).name, "Filename Editor")
    }

    func testRejectsMissingIdentifiersAndNonApplications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingID = try makeApp(in: root, name: "Missing ID", metadata: ["CFBundlePackageType": "APPL"])
        let notApp = try makeApp(in: root, name: "Not an app", metadata: [
            "CFBundlePackageType": "BNDL", "CFBundleIdentifier": "com.example.bundle"
        ])
        XCTAssertThrowsError(try InstalledApplication(url: missingID))
        XCTAssertThrowsError(try InstalledApplication(url: notApp))
        XCTAssertThrowsError(try InstalledApplication(url: root))
    }
}
