import Foundation

public enum UpdateManifest {
    public struct VerifiedUpdate: Equatable, Sendable {
        public let version: AppVersion
        public let versionText: String
        public let packageName: String

        fileprivate init(version: AppVersion, versionText: String, packageName: String) {
            self.version = version
            self.versionText = versionText
            self.packageName = packageName
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case signatureMissing
        case malformed
        case signatureInvalid
        case keyIDMismatch
        case releaseVersionMismatch
        case notNewer
        case belowMinimum(current: String, minimum: String)
        case unexpectedPackage
        case hashMismatch(expected: String, actual: String)
    }

    /// Accepts a manifest only when its signature verifies under one of `trustedPublicKeysBase64`
    /// and its `key_id` names that same key. More than one key is a rotation overlap window;
    /// see `docs/security/update-signing-key-rotation.md`.
    public static func accept(
        manifestBytes: Data,
        signatureText: String,
        trustedPublicKeysBase64: [String],
        releaseVersion: String,
        runningVersion: String,
        packageName: String,
        packageBytes: Data
    ) -> Result<VerifiedUpdate, Failure> {
        let signature = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        if signature.isEmpty {
            return .failure(.signatureMissing)
        }
        if manifestBytes.count > 4096 || signature.utf8.count > 256 {
            return .failure(.malformed)
        }
        let verifyingKeys = trustedPublicKeysBase64.filter {
            UpdateSignature.verify(
                signatureBase64: signature,
                publicKeyBase64: $0,
                data: manifestBytes
            )
        }
        guard !verifyingKeys.isEmpty else {
            return .failure(.signatureInvalid)
        }
        guard let parsed = parse(manifestBytes) else {
            return .failure(.malformed)
        }
        guard verifyingKeys.contains(parsed.keyID) else {
            return .failure(.keyIDMismatch)
        }
        guard parsed.versionText == releaseVersion else {
            return .failure(.releaseVersionMismatch)
        }
        guard let signedVersion = AppVersion(parsed.versionText),
              let running = AppVersion(runningVersion),
              running < signedVersion else {
            return .failure(.notNewer)
        }
        guard let floor = AppVersion(parsed.minFrom) else {
            return .failure(.malformed)
        }
        guard running >= floor else {
            return .failure(.belowMinimum(current: runningVersion, minimum: parsed.minFrom))
        }
        guard let entry = parsed.files.first(where: { $0.file == packageName }) else {
            return .failure(.unexpectedPackage)
        }
        let actual = SHA256Digest.hash(packageBytes).hex
        guard actual == entry.sha256 else {
            return .failure(.hashMismatch(expected: entry.sha256, actual: actual))
        }
        return .success(VerifiedUpdate(
            version: signedVersion,
            versionText: parsed.versionText,
            packageName: packageName
        ))
    }

    static func isReleaseVersionText(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private struct ParsedFile {
        let file: String
        let sha256: String
    }

    private struct Parsed {
        let versionText: String
        let minFrom: String
        let keyID: String
        let files: [ParsedFile]
    }

    private static func parse(_ data: Data) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard Set(object.keys) == ["version", "min_from", "key_id", "files"],
              let version = object["version"] as? String,
              isReleaseVersionText(version),
              let minFrom = object["min_from"] as? String,
              isReleaseVersionText(minFrom),
              let keyID = object["key_id"] as? String,
              let rawFiles = object["files"] as? [[String: Any]],
              rawFiles.count == 3,
              let signedVersion = AppVersion(version),
              let floor = AppVersion(minFrom),
              floor <= signedVersion else {
            return nil
        }
        let expected: [(platform: String, file: String)] = [
            ("macos", "MenuBarMijia-\(version).dmg"),
            ("windows", "MenuBarMijia-\(version)-windows-x64-setup.exe"),
            ("windows", "MenuBarMijia-\(version)-windows-x64.msi"),
        ]
        var files: [ParsedFile] = []
        for (index, raw) in rawFiles.enumerated() {
            guard Set(raw.keys) == ["platform", "file", "sha256"],
                  let platform = raw["platform"] as? String,
                  let name = raw["file"] as? String,
                  let sha256 = raw["sha256"] as? String,
                  platform == expected[index].platform,
                  name == expected[index].file,
                  isLowercaseSHA256(sha256) else {
                return nil
            }
            files.append(ParsedFile(file: name, sha256: sha256))
        }
        return Parsed(versionText: version, minFrom: minFrom, keyID: keyID, files: files)
    }

    private static func isLowercaseSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
