import CryptoKit
import Foundation
import Testing
@testable import MijiaCore

struct UpdateManifestTests {
    @Test("A manifest signed for an older version is a release version mismatch")
    func rejectsManifestSignedForOlderVersion() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let package = Data("dmg-1.1.6".utf8)
        let manifest = manifestBytes(
            version: "1.1.6",
            minFrom: "1.0.0",
            keyID: publicKey,
            digests: (
                SHA256Digest.hash(package).hex,
                String(repeating: "b", count: 64),
                String(repeating: "c", count: 64)
            )
        )
        let signature = try key.signature(for: manifest).base64EncodedString() + "\n"
        let result = UpdateManifest.accept(
            manifestBytes: manifest,
            signatureText: signature,
            publicKeyBase64: publicKey,
            releaseVersion: "1.1.8",
            runningVersion: "1.1.5",
            packageName: "MenuBarMijia-1.1.6.dmg",
            packageBytes: package
        )
        #expect(result == .failure(.releaseVersionMismatch))
    }
}

private func manifestBytes(
    version: String,
    minFrom: String,
    keyID: String,
    digests: (String, String, String)
) -> Data {
    let body = "{\"version\":\"\(version)\",\"min_from\":\"\(minFrom)\",\"key_id\":\"\(keyID)\",\"files\":["
        + "{\"platform\":\"macos\",\"file\":\"MenuBarMijia-\(version).dmg\",\"sha256\":\"\(digests.0)\"},"
        + "{\"platform\":\"windows\",\"file\":\"MenuBarMijia-\(version)-windows-x64-setup.exe\",\"sha256\":\"\(digests.1)\"},"
        + "{\"platform\":\"windows\",\"file\":\"MenuBarMijia-\(version)-windows-x64.msi\",\"sha256\":\"\(digests.2)\"}]}"
    return Data((body + "\n").utf8)
}
