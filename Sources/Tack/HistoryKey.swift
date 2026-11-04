import CryptoKit
import Foundation
import Security

/// The key that encrypts clip history, kept in a file only this user can read.
///
/// It isn't kept in the Keychain because, without a paid Apple Developer team ID, macOS asks
/// for the login password after every update, however the app is signed.
enum HistoryKey {
    enum Lookup {
        case found(SymmetricKey), missing, denied
    }

    private static let fileName = "history.key"
    private static let keySize = 32
    private static let account = "history-encryption-key"
    /// Where earlier versions kept the key, newest first.
    private static let keychainServices = ["io.github.manan-santoki.tack", LegacyMigration.keychainService]

    /// Returns nil if an existing key can't be read, so a new one never replaces it.
    static func loadOrCreate(in directory: URL, earlierKey: () -> Lookup = readFromKeychain) -> SymmetricKey? {
        let url = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), data.count == keySize else {
                NSLog("Tack: couldn't read the history key")
                return nil
            }
            return SymmetricKey(data: data)
        }

        let key: SymmetricKey
        switch earlierKey() {
        case .found(let earlier): key = earlier
        case .denied: return nil
        case .missing: key = SymmetricKey(size: .bits256)
        }
        return save(key, to: url) ? key : nil
    }

    private static func save(_ key: SymmetricKey, to url: URL) -> Bool {
        let files = FileManager.default
        let folder = url.deletingLastPathComponent()
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = key.withUnsafeBytes { Data($0) }
            let temporary = folder.appendingPathComponent(UUID().uuidString)
            guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            try data.write(to: temporary)
            try files.moveItem(at: temporary, to: url)

            // A backup shouldn't hold both the encrypted history and the key that opens it.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var keyURL = url
            try keyURL.setResourceValues(values)
            return true
        } catch {
            NSLog("Tack: couldn't save the history key: \(error)")
            return false
        }
    }

    private static func readFromKeychain() -> Lookup {
        for service in keychainServices {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, data.count == keySize {
                return .found(SymmetricKey(data: data))
            }
            guard status == errSecItemNotFound else {
                NSLog("Tack: Keychain denied the history key: \(status)")
                return .denied
            }
        }
        return .missing
    }
}
