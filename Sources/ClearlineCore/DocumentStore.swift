import Foundation

public struct Library: Codable, Sendable {
    public var schema = 1
    public var documents: [WritingDocument] = []
    public var revisions: [Revision] = []
    public var selectedID: UUID?
    public init() {}
}

public actor DocumentStore {
    public let directory: URL
    private let encoder = JSONEncoder()
    public init(directory: URL) { self.directory = directory; encoder.outputFormatting = [.sortedKeys] }
    private var file: URL { directory.appendingPathComponent("library.json") }
    public func load() throws -> (Library, recovered: Bool) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: file.path) else { return (Library(), false) }
        do { return (try decode(Data(contentsOf: file)), false) }
        catch StoreError.unsupportedSchema { throw StoreError.unsupportedSchema }
        catch {
            let backup = directory.appendingPathComponent("library.backup.json")
            guard let restored = try? decode(Data(contentsOf: backup)) else { throw error }
            // Preserve the damaged file for explicit recovery; never overwrite on a failed load.
            let recovery = directory.appendingPathComponent("library.damaged-\(UUID().uuidString).json")
            try fm.copyItem(at: file, to: recovery)
            return (restored, true)
        }
    }
    private func decode(_ data: Data) throws -> Library {
        let library = try JSONDecoder().decode(Library.self, from: data)
        guard library.schema == 1 else { throw StoreError.unsupportedSchema }
        guard Set(library.documents.map(\.id)).count == library.documents.count else { throw StoreError.invalidLibrary }
        return library
    }
    public func save(_ library: Library, purgeBackup: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("library.backup.json")
        if fm.fileExists(atPath: file.path), let previous = try? Data(contentsOf: file), (try? decode(previous)) != nil {
            try previous.write(to: backup, options: .atomic)
        }
        try encoder.encode(library).write(to: file, options: .atomic)
        if purgeBackup {
            // A delete must not leave private content in the automatic recovery copy.
            try encoder.encode(library).write(to: backup, options: .atomic)
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix("library.damaged-") {
                try fm.removeItem(at: url)
            }
        }
    }
    public func savePreferences(_ preferences: WritingPreferences) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(preferences).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
    }
    public func loadPreferences() throws -> WritingPreferences {
        let url = directory.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return WritingPreferences() }
        // Additive preference migrations inherit defaults; invalid stored types still fail visibly.
        let data = try Data(contentsOf: url)
        guard let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var defaults = try JSONSerialization.jsonObject(with: encoder.encode(WritingPreferences())) as? [String: Any] else { throw StoreError.invalidLibrary }
        defaults.merge(stored) { _, saved in saved }
        var preferences = try JSONDecoder().decode(WritingPreferences.self, from: JSONSerialization.data(withJSONObject: defaults))
        preferences.effort = ModelCapability.capability(for: preferences.model).validatedEffort(preferences.effort)
        return preferences
    }
}
public enum StoreError: String, Error, LocalizedError {
    case unsupportedSchema = "This library was created by a newer version. Your files have not been changed."
    case invalidLibrary = "The library contains duplicate document IDs. Restore a backup before continuing."
    public var errorDescription: String? { rawValue }
}
