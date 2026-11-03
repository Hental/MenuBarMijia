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

    public static func accept(
        manifestBytes: Data,
        signatureText: String,
        publicKeyBase64: String,
        releaseVersion: String,
        runningVersion _: String,
        packageName: String,
        packageBytes _: Data
    ) -> Result<VerifiedUpdate, Failure> {
        guard UpdateSignature.verify(
            signatureBase64: signatureText,
            publicKeyBase64: publicKeyBase64,
            data: manifestBytes
        ) else {
            return .failure(.signatureInvalid)
        }
        guard let version = AppVersion(releaseVersion) else {
            return .failure(.malformed)
        }
        return .success(VerifiedUpdate(
            version: version,
            versionText: releaseVersion,
            packageName: packageName
        ))
    }
}
