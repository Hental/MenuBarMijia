#!/usr/bin/env swift
import CryptoKit
import Foundation

// 私钥格式（MENUBARMIJIA_UPDATE_SIGNING_KEY，二选一）：
//   1. 32 字节 raw seed 的 base64（推荐；44 字符）
//   2. PKCS#8 PEM（OpenSSL 导出的私钥；从 DER 尾部取 32 字节）
//
// 私钥只应保存在离线介质或发布机的 secret 里，绝不提交到仓库。生成一对新密钥可用：
//   swift -e 'import CryptoKit; let k = Curve25519.Signing.PrivateKey(); print("private:", k.rawRepresentation.base64EncodedString()); print("public:", k.publicKey.rawRepresentation.base64EncodedString())'
// 轮换密钥时同步修改 UpdateChecker.updateSigningPublicKeyBase64 和本文档。

// 与 Sources/MijiaCore/UpdateChecker.swift 的 updateSigningPublicKeyBase64 保持一致；
// 轮换密钥时两处一起改，否则这里会拒绝签名。
let expectedPublicKeyBase64 = "rLwWXuP0sOZvgd/KusLTTmBXN9DAZ9EzPBNhFSn9yUo="
let keychainService = "com.jryang1997.release-signing.ed25519"
let keychainAccount = "update-seed-base64"

enum SigningError: Error, CustomStringConvertible {
    case usage
    case missingKey
    case invalidKey(String)
    case keyMismatch(String)
    case invalidPackage(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .usage:
            return "用法：MENUBARMIJIA_UPDATE_SIGNING_KEY=<私钥> swift scripts/sign_update.swift --min-from <x.y.z> <DMG> <EXE> <MSI>"
        case .missingKey:
            return "缺少环境变量 MENUBARMIJIA_UPDATE_SIGNING_KEY（32 字节 seed 的 base64 或 PKCS#8 PEM）"
        case .invalidKey(let detail):
            return "私钥无效：\(detail)"
        case .keyMismatch(let detail):
            return "私钥与 App 内置公钥不匹配：\(detail)"
        case .invalidPackage(let detail):
            return "安装包无效：\(detail)"
        case .writeFailed(let detail):
            return "写入签名文件失败：\(detail)"
        }
    }
}

func decodeSeed(_ raw: String) throws -> Data {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SigningError.missingKey }

    if trimmed.contains("-----BEGIN") {
        let payload = trimmed
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: payload, options: .ignoreUnknownCharacters), der.count >= 32 else {
            throw SigningError.invalidKey("PKCS#8 PEM 不是合法的 base64 DER")
        }
        return Data(der.suffix(32))
    }

    guard let seed = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters), seed.count == 32 else {
        throw SigningError.invalidKey("必须是 32 字节 seed 的 base64 或 PKCS#8 PEM")
    }
    return seed
}

func readKeyFromKeychain() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
        "find-generic-password",
        "-s", keychainService,
        "-a", keychainAccount,
        "-w"
    ]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else { return nil }
        return str
    } catch {
        return nil
    }
}

func isReleaseVersion(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    return parts.allSatisfy { part in
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
    }
}

func versionFromDMG(_ url: URL) throws -> String {
    let name = url.lastPathComponent
    let prefix = "MenuBarMijia-"
    let suffix = ".dmg"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
        throw SigningError.invalidPackage("DMG 文件名必须是 MenuBarMijia-<version>.dmg")
    }
    let version = String(name.dropFirst(prefix.count).dropLast(suffix.count))
    guard isReleaseVersion(version) else {
        throw SigningError.invalidPackage("DMG 版本不是 x.y.z：\(version)")
    }
    return version
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 5, arguments[0] == "--min-from" else { throw SigningError.usage }
    let minFrom = arguments[1]
    guard isReleaseVersion(minFrom) else {
        throw SigningError.invalidPackage("--min-from 必须是 x.y.z")
    }
    let dmgURL = URL(fileURLWithPath: arguments[2])
    let exeURL = URL(fileURLWithPath: arguments[3])
    let msiURL = URL(fileURLWithPath: arguments[4])
    guard let rawKey = ProcessInfo.processInfo.environment["MENUBARMIJIA_UPDATE_SIGNING_KEY"] ?? readKeyFromKeychain() else {
        throw SigningError.missingKey
    }

    let seed = try decodeSeed(rawKey)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard publicKey == expectedPublicKeyBase64 else {
        throw SigningError.keyMismatch("私钥对应的公钥 \(publicKey) 与 App 内置公钥不一致，客户端会拒绝该更新")
    }

    let version = try versionFromDMG(dmgURL)
    let exeName = "MenuBarMijia-\(version)-windows-x64-setup.exe"
    let msiName = "MenuBarMijia-\(version)-windows-x64.msi"
    guard exeURL.lastPathComponent == exeName, msiURL.lastPathComponent == msiName else {
        throw SigningError.invalidPackage("EXE 与 MSI 必须带上与 DMG 相同的版本")
    }
    for package in [dmgURL, exeURL, msiURL] {
        let leftover = package.appendingPathExtension("ed25519.sig")
        if FileManager.default.fileExists(atPath: leftover.path) {
            throw SigningError.invalidPackage("目录里还有旧的安装包签名 \(leftover.lastPathComponent)，请先删除")
        }
    }

    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let manifestTool = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("update_manifest.py")
    encoder.arguments = [
        "python3", manifestTool.path, "encode",
        "--min-from", minFrom,
        "--dmg", dmgURL.path,
        "--exe", exeURL.path,
        "--msi", msiURL.path,
    ]
    var environment: [String: String] = [:]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        environment["PATH"] = path
    }
    encoder.environment = environment
    let encoderError = Pipe()
    encoder.standardError = encoderError
    encoder.standardOutput = FileHandle.nullDevice
    try encoder.run()
    encoder.waitUntilExit()
    if encoder.terminationStatus != 0 {
        let detail = String(data: encoderError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw SigningError.invalidPackage(detail.isEmpty ? "update_manifest.py encode 失败" : detail)
    }

    let manifestURL = dmgURL.deletingLastPathComponent()
        .appendingPathComponent("MenuBarMijia-\(version).update.json")
    let manifestBytes: Data
    do {
        manifestBytes = try Data(contentsOf: manifestURL)
    } catch {
        throw SigningError.invalidPackage(error.localizedDescription)
    }
    let signature = try key.signature(for: manifestBytes)
    let signatureURL = dmgURL.deletingLastPathComponent()
        .appendingPathComponent("MenuBarMijia-\(version).update.json.ed25519.sig")
    do {
        try (signature.base64EncodedString() + "\n").write(to: signatureURL, atomically: true, encoding: .utf8)
    } catch {
        throw SigningError.writeFailed(error.localizedDescription)
    }
    print("✅ 已生成 \(manifestURL.path)")
    print("✅ 已生成 \(signatureURL.path)")
    print("   公钥（与 App 内置值一致）：\(publicKey)")
}

do {
    try main()
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("❌ \(error)\n".utf8))
    exit(1)
}
