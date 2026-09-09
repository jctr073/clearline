import Foundation
import Security
import ClearlineCore

enum KeychainCredential {
    static func read() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Brand.keychainService,
            kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("sk-"), clean.count >= 20, !clean.contains(where: \.isWhitespace) else { throw CredentialError.invalid }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Brand.keychainService, kSecAttrAccount as String: "api-key"]
        let data = Data(clean.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }
    static func delete() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Brand.keychainService, kSecAttrAccount as String: "api-key"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
    /// Parses literal assignments only; never executes shell code, expansion, or substitutions.
    static func importShellAssignment() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let regex = try NSRegularExpression(pattern: #"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:'([^']*)'|"([^"$`\\]*)"|([^\s#;$`\\]+))\s*(?:#.*)?$"#)
        var pending = Data(), candidates: [(String, String)] = []
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] != 10 { pending.append(byte); if pending.count > 100000 { throw CredentialError.invalid }; continue }
            parseLine(); pending.removeAll(keepingCapacity: true)
        }
        if !pending.isEmpty { parseLine() }
        func parseLine() {
            guard let line = String(data: pending, encoding: .utf8), line.contains("OPENAI"), line.contains("KEY"),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { return }
            let source = line as NSString, name = source.substring(with: match.range(at: 1))
            guard name.contains("OPENAI"), name.contains("KEY") else { return }
            for group in 2...4 where match.range(at: group).location != NSNotFound { candidates.append((name, source.substring(with: match.range(at: group)))); break }
        }
        guard let candidate = candidates.last(where: { $0.0 == "OPENAI_API_KEY" }) ?? (candidates.count == 1 ? candidates.first : nil) else { throw CredentialError.assignment }
        try save(candidate.1)
    }
}
enum CredentialError: Error, LocalizedError {
    case invalid, assignment, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid: return "Enter a valid OpenAI API key. It will be stored only in your macOS Keychain."
        case .assignment: return "No unambiguous literal OpenAI key assignment was found in ~/.zshrc. Paste your key in the secure field instead. Shell expressions are never executed."
        case .keychain(let status): return "Keychain access failed (\(status)). Unlock your login Keychain and try again."
        }
    }
}
