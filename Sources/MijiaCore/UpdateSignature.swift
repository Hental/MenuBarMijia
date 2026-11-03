import CryptoKit
import Foundation

// MARK: - Update Signature

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
