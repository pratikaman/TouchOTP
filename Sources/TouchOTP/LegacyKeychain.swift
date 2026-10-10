import Foundation
import Security
import LocalAuthentication
import TouchOTPCore

/// Reads rights that `LARightStore` saved, through the Security framework, so one evaluated `LAContext`
/// can satisfy the biometric constraint on every right's Secure Enclave key instead of prompting per right.
///
/// Observed layout (macOS 26/27): each right is a generic-password item whose service, account and label are
/// `com.apple.LocalAuthentication:Authorization:<identifier>`; its data is an ECIES envelope (0x04 + P-256
/// ephemeral key + ciphertext + GCM tag). The password item itself has no biometric constraint; the matching
/// Secure Enclave key (same string as application tag) carries the current-biometry-set requirement.
///
/// Used only for the one-time migration from per-account rights. Normal operation stays on `LARightStore`.
/// Any mismatch throws so the caller can fall back to `LARight.authorize`, which prompts once per right.
enum LegacyKeychain {
    static let namePrefix = "com.apple.LocalAuthentication:Authorization:"
    /// GCM authentication rejects a wrong variant, so trying several is safe; the common Secure Enclave default is first.
    static let algorithms: [SecKeyAlgorithm] = [
        .eciesEncryptionCofactorVariableIVX963SHA256AESGCM, .eciesEncryptionStandardVariableIVX963SHA256AESGCM,
        .eciesEncryptionCofactorX963SHA256AESGCM, .eciesEncryptionStandardX963SHA256AESGCM,
        .eciesEncryptionCofactorVariableIVX963SHA384AESGCM, .eciesEncryptionStandardVariableIVX963SHA384AESGCM,
        .eciesEncryptionCofactorVariableIVX963SHA512AESGCM, .eciesEncryptionStandardVariableIVX963SHA512AESGCM,
        .eciesEncryptionCofactorVariableIVX963SHA224AESGCM, .eciesEncryptionStandardVariableIVX963SHA224AESGCM
    ]

    static func secret(forRightIdentifier identifier: String, context: LAContext) throws -> Data {
        let name = namePrefix + identifier
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name, kSecAttrAccount as String: name,
            kSecReturnData as String: true, kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var item: CFTypeRef?
        let itemStatus = SecItemCopyMatching(itemQuery as CFDictionary, &item)
        guard itemStatus == errSecSuccess, let envelope = item as? Data else {
            throw OTPError("The protected record could not be read directly (\(itemStatus)).")
        }
        // Never show UI here: the context is already evaluated, and anything else must fall back.
        var keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: Data(name.utf8), kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var keyRef: CFTypeRef?
        var keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyRef)
        if keyStatus != errSecSuccess {
            keyQuery[kSecAttrApplicationTag as String] = nil
            keyQuery[kSecAttrLabel as String] = name
            keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyRef)
        }
        guard keyStatus == errSecSuccess, let keyRef, CFGetTypeID(keyRef) == SecKeyGetTypeID() else {
            throw OTPError("The protected key could not be read directly (\(keyStatus)).")
        }
        let key = keyRef as! SecKey
        var lastError: Error?
        for algorithm in algorithms where SecKeyIsAlgorithmSupported(key, .decrypt, algorithm) {
            var error: Unmanaged<CFError>?
            if let plain = SecKeyCreateDecryptedData(key, algorithm, envelope as CFData, &error) { return plain as Data }
            lastError = error?.takeRetainedValue()
        }
        throw lastError ?? OTPError("The protected record uses an unexpected format.")
    }
}

/// Lists the attributes of every keychain item this app can see. Attributes and envelope shape only, never
/// item data. Behind `--keychain-probe`.
enum KeychainProbe {
    static func report() -> String {
        var lines: [String] = []
        let classes: [(String, CFString)] = [("genericPassword", kSecClassGenericPassword), ("key", kSecClassKey)]
        for (name, cls) in classes {
            let query: [String: Any] = [kSecClass as String: cls, kSecMatchLimit as String: kSecMatchLimitAll,
                                        kSecReturnAttributes as String: true, kSecUseDataProtectionKeychain as String: true,
                                        kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            let items = (result as? [[String: Any]]) ?? []
            lines.append("\(name): status \(status), \(items.count) items")
            for item in items {
                lines.append("  " + item.keys.sorted().map { key in
                    let value = item[key]!
                    if let data = value as? Data {
                        let text = String(data: data, encoding: .utf8).map { " \"\($0.prefix(60))\"" } ?? ""
                        return "\(key)=<\(data.count) bytes>\(text)"
                    }
                    return "\(key)=\(String(describing: value).prefix(80))"
                }.joined(separator: " "))
            }
        }
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true, kSecUseDataProtectionKeychain as String: true,
                                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var one: CFTypeRef?
        let status = SecItemCopyMatching(probe as CFDictionary, &one)
        if let data = one as? Data {
            lines.append("sample envelope: status \(status), \(data.count) bytes, first byte 0x\(String(format: "%02x", data.first ?? 0))")
        } else {
            lines.append("sample envelope: status \(status), no data")
        }
        return lines.joined(separator: "\n")
    }
}
