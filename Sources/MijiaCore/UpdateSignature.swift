import CryptoKit
import Foundation

// MARK: - Update Signature

/// Detached Ed25519 signatures for the release manifest (issue #17, #163).
///
/// The release workflow signs `MenuBarMijia-<version>.update.json` with an offline private key.
/// The matching public key is compiled into the app, so a compromised GitHub account cannot
/// publish an installable update: replacing the manifest requires the private key, and the
/// signed version cannot be replayed as a newer release.
public enum UpdateSignature {
    /// Verifies a base64 detached Ed25519 signature over `data`.
    ///
    /// Returns `false` for malformed keys, malformed signatures, or a genuine mismatch.
    public static func verify(signatureBase64: String, publicKeyBase64: String, data: Data) -> Bool {
        guard let keyData = Data(
                base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              keyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        guard let signatureData = Data(
                base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              signatureData.count == 64 else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: data)
    }
}
