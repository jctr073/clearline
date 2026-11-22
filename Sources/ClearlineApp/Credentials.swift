import Foundation
import Security
import ClearlineCore

extension AIVendor {
    /// OpenAI keeps the original account name so existing keys keep working.
    var keychainAccount: String { self == .openAI ? "api-key" : "gemini-api-key" }
    /// Shell variable names to import, in order of preference.
    var shellVariables: [String] { self == .openAI ? ["OPENAI_API_KEY"] : ["GEMINI_API_KEY", "GOOGLE_API_KEY"] }
    /// Other variable names accepted when exactly one such assignment exists.
    func isImportCandidate(_ name: String) -> Bool {
        self == .openAI ? name.contains("OPENAI") && name.contains("KEY") : shellVariables.contains(name)
    }
    var dataPolicyURL: URL {
        URL(string: self == .openAI ? "https://developers.openai.com/api/docs/guides/your-data" : "https://ai.google.dev/gemini-api/terms")!
    }
    var usageDashboardURL: URL {
        URL(string: self == .openAI ? "https://platform.openai.com/usage" : "https://aistudio.google.com/usage")!
    }
    func isPlausibleKey(_ key: String) -> Bool {
        guard key.count >= 20, key.count <= 512, !key.contains(where: \.isWhitespace) else { return false }
        switch self {
        case .openAI: return key.hasPrefix("sk-")
        // Google issues several key formats (e.g. "AIza…" and "AQ.…"), so check only the character set.
        case .gemini: return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }
}

enum KeychainCredential {
    private static func query(_ vendor: AIVendor) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Brand.keychainService, kSecAttrAccount as String: vendor.keychainAccount]
    }
    static func read(_ vendor: AIVendor) throws -> String? {
        var lookup = query(vendor); lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, for vendor: AIVendor) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard vendor.isPlausibleKey(clean) else { throw CredentialError.invalid(vendor) }
        let data = Data(clean.utf8)
        var status = SecItemUpdate(query(vendor) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(vendor); add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }
    static func delete(_ vendor: AIVendor) throws {
        let status = SecItemDelete(query(vendor) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
    /// Parses literal assignments only; never executes shell code, expansion, or substitutions.
    static func importShellAssignment(for vendor: AIVendor) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let regex = try NSRegularExpression(pattern: #"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:'([^']*)'|"([^"$`\\]*)"|([^\s#;$`\\]+))\s*(?:#.*)?$"#)
        let names = vendor.shellVariables
        var pending = Data(), candidates: [(String, String)] = []
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] != 10 { pending.append(byte); if pending.count > 100000 { throw CredentialError.invalid(vendor) }; continue }
            parseLine(); pending.removeAll(keepingCapacity: true)
        }
        if !pending.isEmpty { parseLine() }
        func parseLine() {
            guard let line = String(data: pending, encoding: .utf8), line.contains("KEY"),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { return }
            let source = line as NSString, name = source.substring(with: match.range(at: 1))
            guard vendor.isImportCandidate(name) else { return }
            for group in 2...4 where match.range(at: group).location != NSNotFound { candidates.append((name, source.substring(with: match.range(at: group)))); break }
        }
        // Prefer the first listed variable; within a name, the last assignment wins as in the shell.
        guard let candidate = names.lazy.compactMap({ name in candidates.last { $0.0 == name } }).first ?? (candidates.count == 1 ? candidates.first : nil) else { throw CredentialError.assignment(vendor) }
        try save(candidate.1, for: vendor)
    }
}
enum CredentialError: Error, LocalizedError {
    case invalid(AIVendor), assignment(AIVendor), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid(let vendor): return "Enter a valid \(vendor.displayName) API key. It will be stored only in your macOS Keychain."
        case .assignment(let vendor): return "No literal \(vendor.shellVariables.joined(separator: " or ")) assignment was found in ~/.zshrc. Paste your key in the secure field instead. Shell expressions are never executed."
        case .keychain(let status): return "Keychain access failed (\(status)). Unlock your login Keychain and try again."
        }
    }
}
