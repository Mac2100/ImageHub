import Foundation
import Security

/// Storage for template secrets: local-admin password, end-user password, domain
/// join credentials, product key, Wi-Fi passphrase.
///
/// Two things about this were originally wrong and caused constant macOS password
/// prompts:
///
/// 1. Every secret was a separate Keychain item, so one template could mean five
///    separate authorisations.
/// 2. `DeploymentTemplate.validationErrors` calls `has(...)`, and that runs from
///    SwiftUI view bodies — so the Keychain was being hit on every redraw.
///
/// Now everything lives in **one** item holding a JSON blob, read once and cached
/// in memory. ImageHub is ad-hoc signed, so its code signature changes with every
/// update and macOS treats each build as a new app asking for access — that part
/// can't be fixed without a paid Developer ID certificate, which is why the
/// file backend below exists as an opt-out.
enum SecretStore {
    /// Distinct secret slots a template can own.
    enum Slot: String, CaseIterable {
        case adminPassword
        case userPassword
        case domainPassword
        case productKey
        case wifiPassword

        var label: String {
            switch self {
            case .adminPassword: return "Admin password"
            case .userPassword: return "User password"
            case .domainPassword: return "Domain join password"
            case .productKey: return "Product key"
            case .wifiPassword: return "Wi-Fi password"
            }
        }
    }

    enum Backend: String, CaseIterable, Identifiable {
        /// macOS Keychain — encrypted at rest by the OS.
        case keychain
        /// A file in Application Support, owner-readable only.
        case file

        var id: String { rawValue }

        var label: String {
            switch self {
            case .keychain: return "macOS Keychain"
            case .file: return "Local file"
            }
        }

        var help: String {
            switch self {
            case .keychain:
                return """
                    Encrypted at rest by macOS. Because ImageHub is ad-hoc signed, its \
                    signature changes with each update and macOS asks for your login \
                    password again after one — once per launch, not once per secret.
                    """
            case .file:
                return """
                    Kept in ImageHub's own folder with owner-only permissions and no \
                    password prompts. Not protected by macOS: anything running as you \
                    can read it. Reasonable if the drives you build already carry these \
                    passwords in clear text anyway, but the Keychain is the safer default.
                    """
            }
        }
    }

    static let backendKey = "secretStorageBackend"
    private static let service = "com.mac2100.ImageHub"
    private static let account = "template-secrets"

    private static let lock = NSLock()
    /// Keyed `"<uuid>.<slot>"`. Nil until first load.
    private static var cache: [String: String]?

    static var backend: Backend {
        get {
            Backend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "")
                ?? .keychain
        }
        set {
            let existing = all()
            UserDefaults.standard.set(newValue.rawValue, forKey: backendKey)
            lock.sync { cache = existing }
            // Carry secrets across so switching storage doesn't lose them.
            write(existing)
        }
    }

    private static func key(_ templateID: UUID, _ slot: Slot) -> String {
        "\(templateID.uuidString).\(slot.rawValue)"
    }

    // MARK: - Public API

    static func get(for templateID: UUID, slot: Slot) -> String? {
        let value = all()[key(templateID, slot)]
        return (value?.isEmpty == false) ? value : nil
    }

    static func has(_ templateID: UUID, slot: Slot) -> Bool {
        get(for: templateID, slot: slot) != nil
    }

    @discardableResult
    static func set(_ secret: String, for templateID: UUID, slot: Slot) -> Bool {
        var secrets = all()
        if secret.isEmpty {
            secrets.removeValue(forKey: key(templateID, slot))
        } else {
            secrets[key(templateID, slot)] = secret
        }
        lock.sync { cache = secrets }
        return write(secrets)
    }

    static func delete(for templateID: UUID, slot: Slot) {
        set("", for: templateID, slot: slot)
    }

    /// Called when a template is deleted so no orphaned secrets are left behind.
    static func deleteAll(for templateID: UUID) {
        var secrets = all()
        for slot in Slot.allCases {
            secrets.removeValue(forKey: key(templateID, slot))
        }
        lock.sync { cache = secrets }
        write(secrets)
    }

    /// Drops the in-memory copy; the next read re-authorises.
    static func forgetCache() {
        lock.sync { cache = nil }
    }

    // MARK: - Backing store

    private static func all() -> [String: String] {
        if let cached = lock.sync({ cache }) { return cached }
        let loaded = read()
        lock.sync { cache = loaded }
        return loaded
    }

    private static func read() -> [String: String] {
        let data: Data?
        switch backend {
        case .keychain: data = readKeychain()
        case .file: data = try? Data(contentsOf: fileURL)
        }
        guard let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    @discardableResult
    private static func write(_ secrets: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        switch backend {
        case .keychain:
            return writeKeychain(data)
        case .file:
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: [.atomic])
                // Owner read/write only.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
                )
                return true
            } catch {
                return false
            }
        }
    }

    private static var fileURL: URL {
        AppPaths.support.appendingPathComponent("secrets.json")
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func writeKeychain(_ data: Data) -> Bool {
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary) == errSecSuccess {
            return true
        }
        var query = baseQuery
        query[kSecValueData as String] = data
        // Available without unlocking a login keychain prompt on every access.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Migration

    /// Moves secrets written by ImageHub ≤ 1.0.2, which used one Keychain item
    /// per template per slot, into the single blob. Runs once.
    static func migrateLegacyItems(for templateIDs: [UUID]) {
        let migratedKey = "didMigrateLegacySecrets"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        var secrets = all()
        var moved = 0
        for id in templateIDs {
            for slot in Slot.allCases {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "\(id.uuidString).\(slot.rawValue)",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var result: AnyObject?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      let data = result as? Data,
                      let value = String(data: data, encoding: .utf8),
                      !value.isEmpty
                else { continue }

                secrets[key(id, slot)] = value
                moved += 1

                query.removeValue(forKey: kSecReturnData as String)
                query.removeValue(forKey: kSecMatchLimit as String)
                SecItemDelete(query as CFDictionary)
            }
        }

        if moved > 0 {
            lock.sync { cache = secrets }
            write(secrets)
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}
