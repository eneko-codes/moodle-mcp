import Foundation
import Security

/// Where the web-service token lives. A protocol so every test runs against an in-memory
/// double and never touches the real Keychain.
public protocol TokenStore: Sendable {
    func readToken() throws(MoodleError) -> String
    func writeToken(_ token: String) throws(MoodleError)
}

/// The login keychain, as a generic password (service `com.eneko.moodle-mcp`, account from
/// the configuration).
///
/// The server must read it with nobody at the keyboard, so `readToken` never allows a
/// dialog: a read the access list does not already permit fails with `tokenNeedsTrust`
/// instead of waiting on a prompt that nobody will answer.
///
/// `writeToken` deletes the item and adds it again rather than updating it in place. An
/// update keeps the old access list, which names whichever program created the item (for
/// an item made with `/usr/bin/security`, only that tool). A fresh add from this binary
/// makes this binary the trusted application. With a stable code signature (a real
/// identity, not ad hoc) that trust is tied to the designated requirement and survives
/// rebuilds.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    /// `false` only for the interactive commands, where a person can answer a dialog.
    public let allowsInteraction: Bool

    public init(
        service: String = Configuration.keychainService, account: String,
        allowsInteraction: Bool = false
    ) {
        self.service = service
        self.account = account
        self.allowsInteraction = allowsInteraction
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func readToken() throws(MoodleError) -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsInteraction {
            // The legacy file keychain honours the process-wide switch; the attribute
            // covers the newer code path. Both, because either alone has been the one
            // that mattered on some macOS release.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            Self.disableKeychainInteraction()
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8),
                !token.isEmpty
            else { throw .keychainFailure(status: status) }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            throw .tokenMissing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw .tokenNeedsTrust(status: status)
        default:
            throw .keychainFailure(status: status)
        }
    }

    public func writeToken(_ token: String) throws(MoodleError) {
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw .keychainFailure(status: deleteStatus)
        }
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrLabel as String] = service
        attributes[kSecAttrDescription as String] = "Moodle web-service token"
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw .keychainFailure(status: addStatus) }
    }

    /// `SecKeychainSetUserInteractionAllowed` is deprecated (as is the attribute above),
    /// but it is still the switch the file-based login keychain consults before showing
    /// its access dialog, and its replacement (`LAContext.interactionNotAllowed`) only
    /// governs the data-protection keychain. The two deprecation warnings are expected.
    private static func disableKeychainInteraction() {
        SecKeychainSetUserInteractionAllowed(false)
    }
}
