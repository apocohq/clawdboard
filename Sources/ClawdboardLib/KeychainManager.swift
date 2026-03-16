import CryptoKit
import Foundation
import Security

/// Manages X25519 keypair generation, macOS Keychain storage, and ECIES decryption
/// for cloud session monitoring.
public class KeychainManager {
    public static let shared = KeychainManager()

    private static let keychainService = "com.clawdboard.cloud"
    private static let keychainAccount = "cloud-private-key"

    // MARK: - Public Key (derived from stored private key)

    /// Returns the public key as a base64-encoded string, or nil if no keypair exists.
    public var publicKeyBase64: String? {
        guard let privateKey = loadPrivateKey() else { return nil }
        let pubKeyData = privateKey.publicKey.rawRepresentation
        return pubKeyData.base64EncodedString()
    }

    /// Channel ID = SHA256(public key raw bytes)[:16] hex
    public var channelId: String? {
        guard let privateKey = loadPrivateKey() else { return nil }
        let pubKeyData = privateKey.publicKey.rawRepresentation
        let hash = SHA256.hash(data: pubKeyData)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a keypair exists in the Keychain.
    public var hasKeypair: Bool {
        loadPrivateKey() != nil
    }

    // MARK: - Keypair Management

    /// Generate a new X25519 keypair and store the private key in the Keychain.
    /// Overwrites any existing keypair.
    @discardableResult
    public func generateKeypair() throws -> String {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        try storePrivateKey(privateKey)
        return privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Delete the keypair from the Keychain.
    public func deleteKeypair() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - ECIES Decryption

    /// Decrypt an ECIES-encrypted blob.
    /// Format: ephemeral_pubkey (32B) || nonce (12B) || ciphertext+tag
    /// Uses ECDH with our private key + HKDF-SHA256 to derive AES-256-GCM key.
    public func decrypt(blob: Data) throws -> Data {
        guard let privateKey = loadPrivateKey() else {
            throw CloudCryptoError.noPrivateKey
        }

        // Parse blob: 32B ephemeral pubkey + 12B nonce + rest is ciphertext+tag
        guard blob.count > 32 + 12 + 16 else {
            throw CloudCryptoError.invalidBlob
        }

        let ephemeralPubKeyData = blob[blob.startIndex..<blob.startIndex + 32]
        let nonceData = blob[blob.startIndex + 32..<blob.startIndex + 32 + 12]
        let ciphertextAndTag = blob[blob.startIndex + 32 + 12...]

        let ephemeralPubKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ephemeralPubKeyData)

        // ECDH shared secret
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPubKey)

        // HKDF-SHA256 to derive AES-256-GCM key
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("clawdboard-ecies".utf8),
            outputByteCount: 32
        )

        // AES-256-GCM decrypt
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(combined: nonceData + ciphertextAndTag)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    // MARK: - Private Helpers

    private func storePrivateKey(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
        let keyData = key.rawRepresentation

        // Delete existing
        deleteKeypair()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudCryptoError.keychainError(status)
        }
    }

    private func loadPrivateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    public enum CloudCryptoError: Error, LocalizedError {
        case noPrivateKey
        case invalidBlob
        case keychainError(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .noPrivateKey:
                return "No private key found in Keychain"
            case .invalidBlob:
                return "Invalid encrypted blob format"
            case .keychainError(let status):
                return "Keychain error: \(status)"
            }
        }
    }
}
