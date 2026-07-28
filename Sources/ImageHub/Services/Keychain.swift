import Foundation
import Security

/// Template secrets (local-admin password, end-user password, domain join
/// credentials, product keys) are stored only in the local macOS Keychain —
/// encrypted at rest by the OS and never written into the template JSON.
///
/// Secrets leave the Keychain in exactly one place: `PayloadBuilder`, when the
/// answer file and provisioning payload are written onto the USB drive you are
/// building. That media is unencrypted by nature, which is why the build sheet
/// warns about it.
enum Keychain {
    private static let service = "com.mac2100.ImageHub"

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

    private static func account(_ templateID: UUID, _ slot: Slot) -> String {
        "\(templateID.uuidString).\(slot.rawValue)"
    }

    private static func baseQuery(_ templateID: UUID, _ slot: Slot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(templateID, slot)
        ]
    }

    @discardableResult
    static func set(_ secret: String, for templateID: UUID, slot: Slot) -> Bool {
        guard !secret.isEmpty else {
            delete(for: templateID, slot: slot)
            return true
        }
        let data = Data(secret.utf8)
        var query = baseQuery(templateID, slot)

        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
            return true
        }

        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(for templateID: UUID, slot: Slot) -> String? {
        var query = baseQuery(templateID, slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ templateID: UUID, slot: Slot) -> Bool {
        get(for: templateID, slot: slot)?.isEmpty == false
    }

    static func delete(for templateID: UUID, slot: Slot) {
        SecItemDelete(baseQuery(templateID, slot) as CFDictionary)
    }

    /// Called when a template is deleted so no orphaned secrets are left behind.
    static func deleteAll(for templateID: UUID) {
        for slot in Slot.allCases {
            delete(for: templateID, slot: slot)
        }
    }
}
