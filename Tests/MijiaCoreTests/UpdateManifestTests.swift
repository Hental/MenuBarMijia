import CryptoKit
import Foundation
import Testing
@testable import MijiaCore

struct UpdateManifestTests {
    @Test("A manifest signed for an older version is a release version mismatch")
    func rejectsManifestSignedForOlderVersion() throws {
        let signed = try signedUpdateManifest(version: "1.1.6", package: Data("dmg-1.1.6".utf8))
        let result = UpdateManifest.accept(
            manifestBytes: signed.bytes,
            signatureText: signed.signatureText,
            trustedPublicKeysBase64: [signed.publicKey],
            releaseVersion: "1.1.8",
            runningVersion: "1.1.5",
            packageName: "MenuBarMijia-1.1.6.dmg",
            packageBytes: signed.package
        )
        #expect(result == .failure(.releaseVersionMismatch))
    }

    @Test("The installed version is not newer when it equals the signed version")
    func rejectsSameRunningVersion() throws {
        let signed = try signedUpdateManifest(version: "1.1.6")
        let result = accept(signed, releaseVersion: "1.1.6", runningVersion: "1.1.6")
        #expect(result == .failure(.notNewer))
    }

    @Test("Changing the version text under the old signature is signature invalid")
    func rejectsVersionTextChangedUnderOldSignature() throws {
        let signed = try signedUpdateManifest(version: "1.1.6")
        var text = String(decoding: signed.bytes, as: UTF8.self)
        let range = try #require(text.range(of: "\"version\":\"1.1.6\""))
        text.replaceSubrange(range, with: "\"version\":\"9.9.9\"")
        let result = UpdateManifest.accept(
            manifestBytes: Data(text.utf8),
            signatureText: signed.signatureText,
            trustedPublicKeysBase64: [signed.publicKey],
            releaseVersion: "9.9.9",
            runningVersion: "1.0.0",
            packageName: "MenuBarMijia-1.1.6.dmg",
            packageBytes: signed.package
        )
        #expect(result == .failure(.signatureInvalid))
    }

    @Test("A valid signature with different package bytes is a hash mismatch")
    func rejectsPackageBytesThatDoNotMatchTheManifest() throws {
        let signed = try signedUpdateManifest(version: "1.1.6")
        let tampered = Data("tampered-dmg".utf8)
        let result = accept(signed, releaseVersion: "1.1.6", runningVersion: "1.1.5", packageBytes: tampered)
        #expect(result == .failure(.hashMismatch(
            expected: SHA256Digest.hash(signed.package).hex,
            actual: SHA256Digest.hash(tampered).hex
        )))
    }

    @Test("key_id must equal the public key that verified the manifest")
    func rejectsKeyIDThatDiffersFromThePublicKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let signed = try signedUpdateManifest(version: "1.1.6", keyID: other, signingKey: key)
        let result = accept(signed, releaseVersion: "1.1.6", runningVersion: "1.1.5")
        #expect(result == .failure(.keyIDMismatch))
    }

    @Test("A manifest signed by the overlap key is accepted during a rotation window")
    func acceptsAOverlapKeyDuringRotation() throws {
        let overlapKey = Curve25519.Signing.PrivateKey()
        let signed = try signedUpdateManifest(version: "1.1.6", signingKey: overlapKey)
        let primaryKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let result = UpdateManifest.accept(
            manifestBytes: signed.bytes,
            signatureText: signed.signatureText,
            trustedPublicKeysBase64: [primaryKey, signed.publicKey],
            releaseVersion: "1.1.6",
            runningVersion: "1.1.5",
            packageName: signed.packageName,
            packageBytes: signed.package
        )
        guard case .success(let verified) = result else {
            Issue.record("expected the overlap key to verify, got \(result)")
            return
        }
        #expect(verified.versionText == "1.1.6")
    }

    @Test("A trusted key_id does not excuse a signature made by another trusted key")
    func rejectsSignatureByAnotherTrustedKey() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let primaryKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let signed = try signedUpdateManifest(version: "1.1.6", keyID: primaryKey, signingKey: signingKey)
        let result = UpdateManifest.accept(
            manifestBytes: signed.bytes,
            signatureText: signed.signatureText,
            trustedPublicKeysBase64: [primaryKey, signed.publicKey],
            releaseVersion: "1.1.6",
            runningVersion: "1.1.5",
            packageName: signed.packageName,
            packageBytes: signed.package
        )
        #expect(result == .failure(.keyIDMismatch))
    }

    @Test("A signature from a key outside the trusted set is invalid")
    func rejectsSignatureFromUntrustedKey() throws {
        let signed = try signedUpdateManifest(version: "1.1.6")
        let untrusted = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let result = UpdateManifest.accept(
            manifestBytes: signed.bytes,
            signatureText: signed.signatureText,
            trustedPublicKeysBase64: [untrusted],
            releaseVersion: "1.1.6",
            runningVersion: "1.1.5",
            packageName: signed.packageName,
            packageBytes: signed.package
        )
        #expect(result == .failure(.signatureInvalid))
    }

    @Test("A running version below min_from is below the minimum")
    func rejectsRunningVersionBelowMinimum() throws {
        let signed = try signedUpdateManifest(version: "1.1.6", minFrom: "1.1.0")
        let result = accept(signed, releaseVersion: "1.1.6", runningVersion: "1.0.9")
        #expect(result == .failure(.belowMinimum(current: "1.0.9", minimum: "1.1.0")))
    }

    @Test("An empty signature is signature missing")
    func rejectsEmptySignature() throws {
        let signed = try signedUpdateManifest(version: "1.1.6")
        let result = UpdateManifest.accept(
            manifestBytes: signed.bytes,
            signatureText: "",
            trustedPublicKeysBase64: [signed.publicKey],
            releaseVersion: "1.1.6",
            runningVersion: "1.1.5",
            packageName: signed.packageName,
            packageBytes: signed.package
        )
        #expect(result == .failure(.signatureMissing))
    }

    @Test("A DMG name that disagrees with the manifest version is malformed")
    func rejectsDMGNameThatDisagreesWithVersion() throws {
        let signed = try signedUpdateManifest(version: "1.1.6", dmgFile: "MenuBarMijia-1.1.7.dmg")
        let result = accept(signed, releaseVersion: "1.1.6", runningVersion: "1.1.5")
        #expect(result == .failure(.malformed))
    }

    @Test("Success returns the signed version text and the package name")
    func successReturnsSignedVersionAndPackageName() throws {
        let signed = try signedUpdateManifest(version: "1.1.7")
        let result = accept(signed, releaseVersion: "1.1.7", runningVersion: "1.1.6")
        guard case .success(let verified) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(verified.versionText == "1.1.7")
        #expect(verified.packageName == "MenuBarMijia-1.1.7.dmg")
        #expect(verified.version == AppVersion("1.1.7"))
    }

    @Test("1.0.10 is newer than 1.0.9")
    func numericCompareTreatsOneZeroTenAsNewer() throws {
        let signed = try signedUpdateManifest(version: "1.0.10")
        let result = accept(signed, releaseVersion: "1.0.10", runningVersion: "1.0.9")
        guard case .success(let verified) = result else {
            Issue.record("expected 1.0.10 to be newer than 1.0.9, got \(result)")
            return
        }
        #expect(verified.versionText == "1.0.10")
    }
}

struct SignedUpdateManifest: Sendable {
    let bytes: Data
    let signatureText: String
    let publicKey: String
    let package: Data
    let packageName: String
}

func signedUpdateManifest(
    version: String,
    minFrom: String = "1.0.0",
    package: Data = Data("dmg-bytes".utf8),
    exeDigest: String = String(repeating: "b", count: 64),
    msiDigest: String = String(repeating: "c", count: 64),
    keyID: String? = nil,
    dmgFile: String? = nil,
    signingKey: Curve25519.Signing.PrivateKey? = nil
) throws -> SignedUpdateManifest {
    let key = signingKey ?? Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let dmgName = dmgFile ?? "MenuBarMijia-\(version).dmg"
    let body = "{\"version\":\"\(version)\",\"min_from\":\"\(minFrom)\",\"key_id\":\"\(keyID ?? publicKey)\",\"files\":["
        + "{\"platform\":\"macos\",\"file\":\"\(dmgName)\",\"sha256\":\"\(SHA256Digest.hash(package).hex)\"},"
        + "{\"platform\":\"windows\",\"file\":\"MenuBarMijia-\(version)-windows-x64-setup.exe\",\"sha256\":\"\(exeDigest)\"},"
        + "{\"platform\":\"windows\",\"file\":\"MenuBarMijia-\(version)-windows-x64.msi\",\"sha256\":\"\(msiDigest)\"}]}\n"
    let bytes = Data(body.utf8)
    let signatureText = try key.signature(for: bytes).base64EncodedString() + "\n"
    return SignedUpdateManifest(
        bytes: bytes,
        signatureText: signatureText,
        publicKey: publicKey,
        package: package,
        packageName: "MenuBarMijia-\(version).dmg"
    )
}

private func accept(
    _ signed: SignedUpdateManifest,
    releaseVersion: String,
    runningVersion: String,
    packageBytes: Data? = nil
) -> Result<UpdateManifest.VerifiedUpdate, UpdateManifest.Failure> {
    UpdateManifest.accept(
        manifestBytes: signed.bytes,
        signatureText: signed.signatureText,
        trustedPublicKeysBase64: [signed.publicKey],
        releaseVersion: releaseVersion,
        runningVersion: runningVersion,
        packageName: signed.packageName,
        packageBytes: packageBytes ?? signed.package
    )
}
