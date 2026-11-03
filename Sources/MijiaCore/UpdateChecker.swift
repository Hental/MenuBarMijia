import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

// MARK: - App Version

/// Dotted numeric version ("v1.10.0", "1.2"); trailing labels such as "-beta" are ignored.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        var parts = numbers.compactMap { $0 }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.parts = parts
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

// MARK: - SHA-256 Digest & Release Metadata

/// Validated 64-character lowercase hexadecimal SHA-256 digest.
public struct SHA256Digest: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    private init(validatedHex: String) {
        self.hex = validatedHex
    }

    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }
        var candidate = String(firstToken).lowercased()
        if candidate.hasPrefix("sha256:") {
            candidate.removeFirst("sha256:".count)
        }
        guard candidate.count == 64, candidate.allSatisfy(\.isHexDigit) else {
            return nil
        }
        self.hex = candidate
    }

    public static func hash(_ data: Data) -> SHA256Digest {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SHA256Digest(validatedHex: hex)
    }

    public static func hashFile(at fileURL: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return SHA256Digest(validatedHex: hex)
    }

    public var description: String { hex }
}

public struct AppRelease: Equatable, Sendable {
    public enum AssetKind: String, Equatable, Sendable {
        case dmg
        case zip
    }

    public struct PackageAsset: Equatable, Sendable {
        public let name: String
        public let downloadURL: URL
        public let sizeBytes: Int64
        public let kind: AssetKind

        public init(
            name: String,
            downloadURL: URL,
            sizeBytes: Int64,
            kind: AssetKind
        ) {
            self.name = name
            self.downloadURL = downloadURL
            self.sizeBytes = sizeBytes
            self.kind = kind
        }
    }

    public let version: String
    public let pageURL: URL
    public let notes: String
    public let packageAsset: PackageAsset?

    public init(
        version: String,
        pageURL: URL,
        notes: String,
        packageAsset: PackageAsset? = nil
    ) {
        self.version = version
        self.pageURL = pageURL
        self.notes = notes
        self.packageAsset = packageAsset
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(receivedBytes: Int64, totalBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(receivedBytes) / Double(totalBytes)))
    }

    public var formattedSummary: String {
        let receivedMB = Double(receivedBytes) / (1024 * 1024)
        if let totalBytes, totalBytes > 0 {
            let totalMB = Double(totalBytes) / (1024 * 1024)
            let percent = Int((fractionCompleted ?? 0) * 100)
            return String(format: "%.1f / %.1f MB (%d%%)", receivedMB, totalMB, percent)
        }
        return String(format: "%.1f MB", receivedMB)
    }
}

/// Proof token constructed only after the signed update manifest, bundle identifier, version, optional quarantine removal, and code signature checks pass.
public struct VerifiedStagedApp: Equatable, Sendable {
    public let release: AppRelease
    public let stagedBundleURL: URL
    public let stagingRootURL: URL

    internal init(release: AppRelease, stagedBundleURL: URL, stagingRootURL: URL) {
        self.release = release
        self.stagedBundleURL = stagedBundleURL
        self.stagingRootURL = stagingRootURL
    }
}

public struct AppUpdateFailure: Equatable, Sendable {
    public let release: AppRelease?
    public let message: String
    public let canRetryInstall: Bool

    public init(release: AppRelease?, message: String, canRetryInstall: Bool) {
        self.release = release
        self.message = message
        self.canRetryInstall = canRetryInstall
    }

    public var fallbackURL: URL {
        release?.pageURL ?? UpdateChecker.releasesPage
    }
}

public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(AppRelease)
    case downloading(AppRelease, progress: DownloadProgress)
    case verifying(AppRelease)
    case readyToRelaunch(VerifiedStagedApp)
    case installing(AppRelease)
    case failed(AppUpdateFailure)

    public var associatedRelease: AppRelease? {
        switch self {
        case .available(let release),
             .downloading(let release, _),
             .verifying(let release),
             .installing(let release):
            return release
        case .readyToRelaunch(let staged):
            return staged.release
        case .failed(let failure):
            return failure.release
        case .idle, .checking, .upToDate:
            return nil
        }
    }

    public var badgeRelease: AppRelease? {
        switch self {
        case .available(let release),
             .downloading(let release, _),
             .verifying(let release):
            return release
        case .readyToRelaunch(let staged):
            return staged.release
        default:
            return nil
        }
    }

    public var isReadyToRelaunch: Bool {
        if case .readyToRelaunch = self { return true }
        return false
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Update Checker

public struct UpdateChecker: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum CheckError: LocalizedError, Equatable {
        case httpStatus(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return L10n.tr("检查更新失败（\(code)），稍后再试", "Update check failed (\(code)); try again later")
            case .malformed:
                return L10n.tr("检查更新失败：返回内容看不懂", "Update check failed: unexpected response")
            }
        }
    }

    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/jryang1997/MenuBarMijia/releases")!

    /// Ed25519 public key (32-byte raw, base64) that the release manifest must be signed with.
    /// The private key should stay offline; see `scripts/sign_update.swift` and ADR-0005.
    public static let updateSigningPublicKeyBase64 = "rLwWXuP0sOZvgd/KusLTTmBXN9DAZ9EzPBNhFSn9yUo="

    public let currentVersion: String
    private let transport: Transport

    public init(currentVersion: String, transport: Transport? = nil) {
        self.currentVersion = currentVersion
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    /// The running app's CFBundleShortVersionString ("0" when run from `swift run`).
    public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public func checkRelease() async throws -> AppRelease? {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw CheckError.httpStatus(status) }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let latest = AppVersion(tag) else {
            throw CheckError.malformed
        }
        guard let current = AppVersion(currentVersion), latest > current else {
            return nil
        }
        let url = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
        let shown = tag.lowercased().hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = object["body"] as? String ?? ""
        let rawAssets = object["assets"] as? [[String: Any]] ?? []
        let packageAsset = Self.selectPackageAsset(version: shown, from: rawAssets)
        return AppRelease(version: shown, pageURL: url, notes: notes, packageAsset: packageAsset)
    }

    /// GitHub release URL for one of the eight publish names. `browser_download_url` is not used.
    public static func releaseAssetURL(version: String, fileName: String) -> URL? {
        guard UpdateManifest.isReleaseVersionText(version) else { return nil }
        let allowed: Set<String> = [
            "MenuBarMijia-\(version).dmg",
            "MenuBarMijia-\(version).dmg.sha256",
            "MenuBarMijia-\(version)-windows-x64-setup.exe",
            "MenuBarMijia-\(version)-windows-x64-setup.exe.sha256",
            "MenuBarMijia-\(version)-windows-x64.msi",
            "MenuBarMijia-\(version)-windows-x64.msi.sha256",
            "MenuBarMijia-\(version).update.json",
            "MenuBarMijia-\(version).update.json.ed25519.sig",
        ]
        guard allowed.contains(fileName) else { return nil }
        return URL(string: "https://github.com/jryang1997/MenuBarMijia/releases/download/v\(version)/\(fileName)")
    }

    private static func selectPackageAsset(version: String, from rawAssets: [[String: Any]]) -> AppRelease.PackageAsset? {
        let dmgName = "MenuBarMijia-\(version).dmg"
        let manifestName = "MenuBarMijia-\(version).update.json"
        guard let downloadURL = releaseAssetURL(version: version, fileName: dmgName) else {
            return nil
        }
        var sawDMG = false
        var sawManifest = false
        var sizeBytes: Int64 = 0
        for item in rawAssets {
            guard let name = item["name"] as? String else { continue }
            if name == dmgName {
                sawDMG = true
                if let int64Size = item["size"] as? Int64 {
                    sizeBytes = int64Size
                } else if let intSize = item["size"] as? Int {
                    sizeBytes = Int64(intSize)
                } else if let numberSize = item["size"] as? NSNumber {
                    sizeBytes = numberSize.int64Value
                }
            } else if name == manifestName {
                sawManifest = true
            }
        }
        guard sawDMG, sawManifest else { return nil }
        return AppRelease.PackageAsset(
            name: dmgName,
            downloadURL: downloadURL,
            sizeBytes: sizeBytes,
            kind: .dmg
        )
    }
}

// MARK: - In-App Update Installer

public enum UpdateInstallError: LocalizedError, Equatable, Sendable {
    case missingPackageAsset
    case notRunningFromAppBundle
    case targetLocationNotWritable(String)
    case checksumMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case bundleIdentifierMismatch(found: String?)
    case bundleVersionMismatch(found: String?, expected: String)
    case codeSignatureInvalid(String)
    case updateSignatureMissing
    case updateSignatureInvalid(String)
    case updateBelowMinimum(current: String, minimum: String)
    case relaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingPackageAsset:
            return L10n.tr(
                "该版本未提供可自动安装的安装包，请前往下载页手动更新",
                "This release does not include an installable package; please download manually"
            )
        case .notRunningFromAppBundle:
            return L10n.tr(
                "当前未从 .app 应用包运行，请前往下载页手动安装",
                "Not running from an .app bundle; please install manually"
            )
        case .targetLocationNotWritable(let path):
            return L10n.tr(
                "无法写入应用目录（\(path)），请将应用移至「应用程序」文件夹或手动替换",
                "Cannot write to application directory (\(path)); move the app to Applications or replace manually"
            )
        case .checksumMismatch(let expected, let actual):
            return L10n.tr(
                "安装包 SHA-256 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）",
                "Package SHA-256 verification failed (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
            )
        case .unpackFailed(let detail):
            return L10n.tr(
                "解压更新包失败：\(detail)",
                "Failed to unpack update archive: \(detail)"
            )
        case .bundleIdentifierMismatch(let found):
            return L10n.tr(
                "更新包应用标识符不匹配（\(found ?? "未知")）",
                "Bundle identifier mismatch (\(found ?? "unknown"))"
            )
        case .bundleVersionMismatch(let found, let expected):
            return L10n.tr(
                "更新包版本号不匹配（发现 \(found ?? "未知")，期望 \(expected)）",
                "Bundle version mismatch (found \(found ?? "unknown"), expected \(expected))"
            )
        case .codeSignatureInvalid(let detail):
            return L10n.tr(
                "更新包签名校验失败：\(detail)",
                "Code signature verification failed: \(detail)"
            )
        case .updateSignatureMissing:
            return L10n.tr(
                "更新包缺少 Ed25519 数字签名（.update.json.ed25519.sig），已中止安装",
                "Update package is missing its Ed25519 signature (.update.json.ed25519.sig); installation aborted"
            )
        case .updateBelowMinimum(let current, let minimum):
            return L10n.tr(
                "当前版本 \(current) 低于此更新要求的最低版本 \(minimum)，已中止安装",
                "Installed version \(current) is below the minimum \(minimum) required by this update; installation aborted"
            )
        case .updateSignatureInvalid(let detail):
            return L10n.tr(
                "更新包 Ed25519 数字签名校验失败：\(detail)",
                "Update package Ed25519 signature verification failed: \(detail)"
            )
        case .relaunchFailed(let detail):
            return L10n.tr(
                "启动更新替换脚本失败：\(detail)",
                "Failed to launch update script: \(detail)"
            )
        }
    }
}

public struct UpdateSystemDriver: Sendable {
    public var downloadFile: @Sendable (
        _ url: URL,
        _ destination: URL,
        _ onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> Void
    public var fetchData: UpdateChecker.Transport
    public var unpackArchive: @Sendable (
        _ archiveURL: URL,
        _ kind: AppRelease.AssetKind,
        _ destinationDir: URL
    ) async throws -> URL
    public var stripQuarantine: @Sendable (_ appBundleURL: URL) async throws -> Void
    public var verifyCodeSignature: @Sendable (_ appBundleURL: URL, _ requirement: String) async throws -> Void
    public var launchDetachedSwapAndRelaunch: @Sendable (
        _ staged: VerifiedStagedApp,
        _ targetBundleURL: URL,
        _ currentPID: Int32
    ) throws -> Void

    public init(
        downloadFile: @escaping @Sendable (
            _ url: URL,
            _ destination: URL,
            _ onProgress: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> Void,
        fetchData: @escaping UpdateChecker.Transport = { try await URLSession.shared.data(for: $0) },
        unpackArchive: @escaping @Sendable (
            _ archiveURL: URL,
            _ kind: AppRelease.AssetKind,
            _ destinationDir: URL
        ) async throws -> URL,
        stripQuarantine: @escaping @Sendable (_ appBundleURL: URL) async throws -> Void = { _ in },
        verifyCodeSignature: @escaping @Sendable (_ appBundleURL: URL, _ requirement: String) async throws -> Void,
        launchDetachedSwapAndRelaunch: @escaping @Sendable (
            _ staged: VerifiedStagedApp,
            _ targetBundleURL: URL,
            _ currentPID: Int32
        ) throws -> Void
    ) {
        self.downloadFile = downloadFile
        self.fetchData = fetchData
        self.unpackArchive = unpackArchive
        self.stripQuarantine = stripQuarantine
        self.verifyCodeSignature = verifyCodeSignature
        self.launchDetachedSwapAndRelaunch = launchDetachedSwapAndRelaunch
    }

    public static let live = UpdateSystemDriver(
        downloadFile: { url, destination, onProgress in
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("MenuBarMijia", forHTTPHeaderField: "User-Agent")
            #if os(macOS)
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                throw UpdateChecker.CheckError.httpStatus(status)
            }
            let expectedLength = response.expectedContentLength
            let totalBytes: Int64? = expectedLength > 0 ? expectedLength : nil

            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var receivedBytes: Int64 = 0
            var lastReportedAt = ContinuousClock.now

            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    receivedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    let now = ContinuousClock.now
                    if now - lastReportedAt >= .milliseconds(60) {
                        lastReportedAt = now
                        onProgress(DownloadProgress(receivedBytes: receivedBytes, totalBytes: totalBytes))
                    }
                }
            }

            if !buffer.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: false)
            }
            onProgress(DownloadProgress(receivedBytes: receivedBytes, totalBytes: totalBytes))
            #else
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                throw UpdateChecker.CheckError.httpStatus(status)
            }
            try data.write(to: destination, options: .atomic)
            let count = Int64(data.count)
            onProgress(DownloadProgress(receivedBytes: count, totalBytes: count))
            #endif
        },
        fetchData: { try await URLSession.shared.data(for: $0) },
        unpackArchive: { archiveURL, kind, destinationDir in
            switch kind {
            case .dmg:
                return try await Self.unpackDMG(at: archiveURL, destinationDir: destinationDir)
            case .zip:
                return try await Self.unpackZIP(at: archiveURL, destinationDir: destinationDir)
            }
        },
        stripQuarantine: { appBundleURL in
            _ = try? await Self.runProcess(
                executable: "/usr/bin/xattr",
                arguments: ["-dr", "com.apple.quarantine", appBundleURL.path]
            )
        },
        verifyCodeSignature: { appBundleURL, requirement in
            let result = try await Self.runProcess(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--deep", "-R=\(requirement)", appBundleURL.path]
            )
            guard result.exitCode == 0 else {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdateInstallError.codeSignatureInvalid(message.isEmpty ? "exit \(result.exitCode)" : message)
            }
        },
        launchDetachedSwapAndRelaunch: { staged, targetBundleURL, currentPID in
            let parentDir = targetBundleURL.deletingLastPathComponent()
            let backupURL = parentDir.appendingPathComponent(".\(targetBundleURL.lastPathComponent).backup-\(currentPID)")
            let script = """
            i=0
            while kill -0 "$WAIT_PID" 2>/dev/null; do
                i=$((i + 1))
                if [ "$i" -ge 150 ]; then
                    break
                fi
                sleep 0.1
            done
            if kill -0 "$WAIT_PID" 2>/dev/null; then
                exit 1
            fi
            rm -rf "$BACKUP_APP"
            if [ -e "$TARGET_APP" ]; then
                mv "$TARGET_APP" "$BACKUP_APP" || exit 1
            fi
            if mv "$STAGED_APP" "$TARGET_APP"; then
                rm -rf "$BACKUP_APP" "$STAGING_ROOT"
                /usr/bin/open "$TARGET_APP"
            else
                if [ -e "$BACKUP_APP" ]; then
                    rm -rf "$TARGET_APP"
                    mv "$BACKUP_APP" "$TARGET_APP"
                fi
                exit 1
            fi
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            var env = ProcessInfo.processInfo.environment
            env["WAIT_PID"] = String(currentPID)
            env["STAGED_APP"] = staged.stagedBundleURL.path
            env["TARGET_APP"] = targetBundleURL.path
            env["BACKUP_APP"] = backupURL.path
            env["STAGING_ROOT"] = staged.stagingRootURL.path
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw UpdateInstallError.relaunchFailed(error.localizedDescription)
            }
        }
    )

    private struct ProcessOutput: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: String
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        terminateOnCancel: Bool = true
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            if terminateOnCancel {
                try Task.checkCancellation()
            }
            try process.run()
            if terminateOnCancel && Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            let outReadHandle = outPipe.fileHandleForReading
            let errReadHandle = errPipe.fileHandleForReading
            async let outData = Task.detached(priority: .userInitiated) {
                outReadHandle.readDataToEndOfFile()
            }.value
            async let errData = Task.detached(priority: .userInitiated) {
                errReadHandle.readDataToEndOfFile()
            }.value
            let (stdout, stderrData) = await (outData, errData)
            #if os(macOS)
            while process.isRunning {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #else
            await Task.detached(priority: .userInitiated) {
                process.waitUntilExit()
            }.value
            #endif
            if terminateOnCancel {
                try Task.checkCancellation()
            }
            return ProcessOutput(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        } onCancel: {
            if terminateOnCancel, process.isRunning {
                process.terminate()
            }
        }
    }

    private static func detachMountPoints(_ mountPoints: [String]) async {
        for mountPoint in mountPoints {
            _ = try? await runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint, "-force"],
                terminateOnCancel: false
            )
        }
    }

    private static func unpackDMG(at dmgURL: URL, destinationDir: URL) async throws -> URL {
        let mountParent = destinationDir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountParent, withIntermediateDirectories: true)
        let attachArguments = ["attach", "-nobrowse", "-readonly", "-noverify", "-mountrandom", mountParent.path, "-plist", dmgURL.path]
        var attachResult = try await runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: attachArguments
        )
        var attempt = 1
        while attachResult.exitCode != 0 && attempt < 5 {
            try await Task.sleep(for: .milliseconds(250 * attempt))
            attachResult = try await runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: attachArguments
            )
            attempt += 1
        }
        guard attachResult.exitCode == 0 else {
            try? FileManager.default.removeItem(at: mountParent)
            let reason = attachResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateInstallError.unpackFailed(reason.isEmpty ? "hdiutil attach (\(attachResult.exitCode))" : reason)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: attachResult.stdout, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            try? FileManager.default.removeItem(at: mountParent)
            throw UpdateInstallError.unpackFailed("Missing mount-point in hdiutil plist")
        }
        let mountPoints = entities
            .compactMap { $0["mount-point"] as? String }
            .filter { !$0.isEmpty }
        guard !mountPoints.isEmpty else {
            try? FileManager.default.removeItem(at: mountParent)
            throw UpdateInstallError.unpackFailed("Missing mount-point in hdiutil plist")
        }

        do {
            var foundAppURL: URL?
            for mountPoint in mountPoints {
                let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
                if let candidate = try findAppBundle(in: mountURL) {
                    foundAppURL = candidate
                    break
                }
            }
            guard let mountedAppURL = foundAppURL else {
                throw UpdateInstallError.unpackFailed("No .app bundle found in mounted DMG")
            }
            let stagedAppURL = destinationDir.appendingPathComponent(mountedAppURL.lastPathComponent, isDirectory: true)
            let dittoResult = try await runProcess(
                executable: "/usr/bin/ditto",
                arguments: [mountedAppURL.path, stagedAppURL.path]
            )
            guard dittoResult.exitCode == 0 else {
                let reason = dittoResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdateInstallError.unpackFailed(reason.isEmpty ? "ditto copy failed" : reason)
            }
            await detachMountPoints(mountPoints)
            try? FileManager.default.removeItem(at: mountParent)
            return stagedAppURL
        } catch {
            await detachMountPoints(mountPoints)
            try? FileManager.default.removeItem(at: mountParent)
            throw error
        }
    }

    private static func unpackZIP(at zipURL: URL, destinationDir: URL) async throws -> URL {
        let extractDir = destinationDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let dittoResult = try await runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipURL.path, extractDir.path]
        )
        guard dittoResult.exitCode == 0 else {
            let reason = dittoResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateInstallError.unpackFailed(reason.isEmpty ? "ditto unzip failed" : reason)
        }
        guard let extractedAppURL = try findAppBundle(in: extractDir) else {
            throw UpdateInstallError.unpackFailed("No .app bundle found in ZIP archive")
        }
        let stagedAppURL = destinationDir.appendingPathComponent(extractedAppURL.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: extractedAppURL, to: stagedAppURL)
        try? FileManager.default.removeItem(at: extractDir)
        return stagedAppURL
    }

    private static func findAppBundle(in directory: URL) throws -> URL? {
        let preferred = directory.appendingPathComponent("MenuBarMijia.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.first { $0.pathExtension.lowercased() == "app" }
    }
}

public struct AppUpdater: Sendable {
    public static let expectedBundleIdentifier = KeychainHelper.service
    private static let stagingDirectoryPrefix = "\(expectedBundleIdentifier).update-"

    private let checker: UpdateChecker
    private let driver: UpdateSystemDriver
    private let targetBundleURL: URL
    private let stagingBaseDirectory: URL
    private let updateSigningPublicKeyBase64: String

    public init(
        currentVersion: String = UpdateChecker.bundleVersion,
        targetBundleURL: URL = Bundle.main.bundleURL,
        stagingBaseDirectory: URL = FileManager.default.temporaryDirectory,
        updateSigningPublicKeyBase64: String = UpdateChecker.updateSigningPublicKeyBase64,
        driver: UpdateSystemDriver = .live
    ) {
        self.checker = UpdateChecker(currentVersion: currentVersion, transport: driver.fetchData)
        self.driver = driver
        self.targetBundleURL = targetBundleURL
        self.stagingBaseDirectory = stagingBaseDirectory
        self.updateSigningPublicKeyBase64 = updateSigningPublicKeyBase64
    }

    public func checkLatestRelease() async throws -> AppRelease? {
        try await checker.checkRelease()
    }

    public func stageUpdate(
        for release: AppRelease,
        onPhaseChange: @escaping @Sendable (AppUpdateState) -> Void
    ) async throws -> VerifiedStagedApp {
        try validateTargetBundleWritable()
        guard let asset = release.packageAsset else {
            throw UpdateInstallError.missingPackageAsset
        }
        guard let packageURL = UpdateChecker.releaseAssetURL(version: release.version, fileName: asset.name),
              let manifestURL = UpdateChecker.releaseAssetURL(
                version: release.version,
                fileName: "MenuBarMijia-\(release.version).update.json"
              ),
              let signatureURL = UpdateChecker.releaseAssetURL(
                version: release.version,
                fileName: "MenuBarMijia-\(release.version).update.json.ed25519.sig"
              ) else {
            throw UpdateInstallError.updateSignatureInvalid("release asset name is not publishable")
        }

        sweepStaleStagingDirectories()
        let stagingRootURL = stagingBaseDirectory.appendingPathComponent(
            "\(Self.stagingDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        var keepStaging = false
        defer {
            if !keepStaging {
                try? FileManager.default.removeItem(at: stagingRootURL)
            }
        }

        let archiveURL = stagingRootURL.appendingPathComponent("package.\(asset.kind.rawValue)")
        let initialTotal: Int64? = asset.sizeBytes > 0 ? asset.sizeBytes : nil
        onPhaseChange(.downloading(release, progress: DownloadProgress(receivedBytes: 0, totalBytes: initialTotal)))

        try await driver.downloadFile(packageURL, archiveURL) { progress in
            onPhaseChange(.downloading(release, progress: progress))
        }
        try Task.checkCancellation()

        onPhaseChange(.verifying(release))
        let manifestBytes = try await fetchReleaseFile(
            from: manifestURL,
            missing: UpdateInstallError.updateSignatureInvalid("update manifest is missing")
        )
        let signatureData = try await fetchReleaseFile(
            from: signatureURL,
            missing: UpdateInstallError.updateSignatureMissing
        )
        guard let signatureText = String(data: signatureData, encoding: .utf8) else {
            throw UpdateInstallError.updateSignatureInvalid("signature file is not UTF-8")
        }
        let packageBytes: Data
        do {
            packageBytes = try Data(contentsOf: archiveURL)
        } catch {
            throw UpdateInstallError.updateSignatureInvalid("cannot read the downloaded package")
        }
        let decision = UpdateManifest.accept(
            manifestBytes: manifestBytes,
            signatureText: signatureText,
            publicKeyBase64: updateSigningPublicKeyBase64,
            releaseVersion: release.version,
            runningVersion: checker.currentVersion,
            packageName: asset.name,
            packageBytes: packageBytes
        )
        let verified: UpdateManifest.VerifiedUpdate
        switch decision {
        case .success(let value):
            verified = value
        case .failure(let failure):
            throw Self.installError(for: failure)
        }
        try Task.checkCancellation()

        let stagedBundleURL = try await driver.unpackArchive(archiveURL, asset.kind, stagingRootURL)
        try? FileManager.default.removeItem(at: archiveURL)
        try Task.checkCancellation()

        try validateBundleMetadata(at: stagedBundleURL, expectedVersion: verified.versionText)
        if Self.shouldStripQuarantine(currentAppIsAdHoc: Self.currentAppIsAdHoc()) {
            try await driver.stripQuarantine(stagedBundleURL)
        }
        let requirement = Self.codeSigningRequirement(
            bundleIdentifier: Self.expectedBundleIdentifier,
            certificateSHA1: Self.codeSignCertificateSHA1(at: targetBundleURL)
        )
        try await driver.verifyCodeSignature(stagedBundleURL, requirement)
        try Task.checkCancellation()

        keepStaging = true
        return VerifiedStagedApp(
            release: release,
            stagedBundleURL: stagedBundleURL,
            stagingRootURL: stagingRootURL
        )
    }

    public func installStagedUpdateAndRelaunch(_ staged: VerifiedStagedApp) throws {
        try validateTargetBundleWritable()
        try driver.launchDetachedSwapAndRelaunch(
            staged,
            targetBundleURL,
            ProcessInfo.processInfo.processIdentifier
        )
    }

    public func cleanupStagedApp(_ staged: VerifiedStagedApp) {
        try? FileManager.default.removeItem(at: staged.stagingRootURL)
    }

    /// `codesign` requirement used to verify the staged bundle.
    ///
    /// The pinned leaf certificate hash itself is the anchor. `anchor apple generic` is not
    /// assumed because the release certificate is self-signed and would never satisfy it;
    /// missing or malformed pins fail closed, including local development builds.
    /// The signed update manifest is independently mandatory.
    public static func codeSigningRequirement(bundleIdentifier: String, certificateSHA1: String?) -> String {
        let base = "identifier \"\(bundleIdentifier)\""
        guard let raw = certificateSHA1?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return base + " and never"
        }
        let hash = raw.replacingOccurrences(of: " ", with: "").lowercased()
        guard hash.utf8.count == 40,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return base + " and never"
        }
        return base + " and certificate leaf = H\"\(hash)\""
    }

    /// Whether the staged bundle may have its quarantine attribute removed.
    ///
    /// Only non-Apple-anchored (ad-hoc or self-signed local) builds need this so in-app updates
    /// keep working; official signed builds keep quarantine and let Gatekeeper check the
    /// replacement app.
    public static func shouldStripQuarantine(currentAppIsAdHoc: Bool) -> Bool {
        currentAppIsAdHoc
    }

    /// True when the running app's designated requirement is not Apple-anchored.
    ///
    /// Failing to read the requirement is treated as ad-hoc to avoid breaking local updates.
    public static func currentAppIsAdHoc() -> Bool {
        #if os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return true
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return true
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess, let text else {
            return true
        }
        return !(text as String).lowercased().contains("anchor apple generic")
        #else
        return true
        #endif
    }

    private static func codeSignCertificateSHA1(at appBundleURL: URL) -> String? {
        let infoPlistURL = appBundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let raw = plist["MijiaCodeSignCertSHA1"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateTargetBundleWritable() throws {
        guard targetBundleURL.pathExtension.lowercased() == "app" else {
            throw UpdateInstallError.notRunningFromAppBundle
        }
        let parentPath = targetBundleURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parentPath) else {
            throw UpdateInstallError.targetLocationNotWritable(parentPath)
        }
    }

    private func sweepStaleStagingDirectories() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stagingBaseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(Self.stagingDirectoryPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func fetchReleaseFile(from url: URL, missing: UpdateInstallError) async throws -> Data {
        let request = URLRequest(url: url, timeoutInterval: 15)
        let (data, response) = try await driver.fetchData(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 {
            throw missing
        }
        guard (200..<300).contains(status) else {
            throw UpdateChecker.CheckError.httpStatus(status)
        }
        return data
    }

    private static func installError(for failure: UpdateManifest.Failure) -> UpdateInstallError {
        switch failure {
        case .signatureMissing:
            return .updateSignatureMissing
        case .hashMismatch(let expected, let actual):
            return .checksumMismatch(expected: expected, actual: actual)
        case .belowMinimum(let current, let minimum):
            return .updateBelowMinimum(current: current, minimum: minimum)
        case .signatureInvalid:
            return .updateSignatureInvalid("signature does not match the manifest")
        case .malformed:
            return .updateSignatureInvalid("update manifest is malformed")
        case .keyIDMismatch:
            return .updateSignatureInvalid("update manifest key id does not match")
        case .releaseVersionMismatch:
            return .updateSignatureInvalid("update manifest is signed for a different version")
        case .notNewer:
            return .updateSignatureInvalid("update manifest is not newer than the installed version")
        case .unexpectedPackage:
            return .updateSignatureInvalid("update package is not listed in the manifest")
        }
    }

    private func validateBundleMetadata(at appBundleURL: URL, expectedVersion: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: appBundleURL.path)
        let fileType = attributes[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink || fileType != .typeDirectory {
            throw UpdateInstallError.unpackFailed("App bundle cannot be a symbolic link")
        }
        let infoPlistURL = appBundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw UpdateInstallError.bundleIdentifierMismatch(found: nil)
        }
        let bundleID = plist["CFBundleIdentifier"] as? String
        guard bundleID == Self.expectedBundleIdentifier else {
            throw UpdateInstallError.bundleIdentifierMismatch(found: bundleID)
        }
        if let expected = AppVersion(expectedVersion) {
            let rawFound = plist["CFBundleShortVersionString"] as? String
            guard let foundString = rawFound,
                  let found = AppVersion(foundString),
                  found == expected else {
                throw UpdateInstallError.bundleVersionMismatch(found: rawFound, expected: expectedVersion)
            }
        }
    }
}
