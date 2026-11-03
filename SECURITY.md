# Security policy

This page is the security policy for MenuBarMijia.

It names the supported release, how you report a vulnerability, when you can expect an acknowledgement, and which reports are in scope.

## Supported versions

The only supported release is the GitHub Release marked Latest.

Older tagged releases are not supported.

There is no maintenance branch.

The version digits live only in the root `VERSION` file.

This page does not copy them.

A vulnerability in an area under [In scope](#in-scope) is in scope on an older build when the Latest release still has it.

The same vulnerability is in scope on the current `main` branch when the Latest release does not have it yet.

## Reporting a vulnerability

1. Open the [Security tab](https://github.com/jryang1997/MenuBarMijia/security) for this repository.
2. If a report for this vulnerability is already open, add the new information to that report.
3. If no report is open and the tab shows a button named **Report a vulnerability**, use that button.
4. Do not open a public issue for the same vulnerability.

The report that button files is visible to you and the maintainer.

If the tab does not show that button, this policy gives you no other channel.

Include these facts.

- The version the app shows.
- Whether that version is the GitHub Release marked Latest.
- Which area under [In scope](#in-scope) is affected.
- What an attacker can do.

Leave out secrets from the stores under [Credential storage](#credential-storage).

## Response

The maintainer acknowledges a submitted report within 7 calendar days.

Count those days from the time you submit the report.

The acknowledgement means the report was received.

This policy states no patch date.

A fix, when one ships, ships only as a newer GitHub Release marked Latest.

Ask in the private report before you publish any details.

## Verifying release artifacts

The `Release` workflow attaches build provenance attestations and a software bill of materials (SBOM) to every release.

The attestations cover the three installers:

- `MenuBarMijia-<version>.dmg`
- `MenuBarMijia-<version>-windows-x64-setup.exe`
- `MenuBarMijia-<version>-windows-x64.msi`

Verify a downloaded installer with [GitHub CLI](https://cli.github.com) 2.49 or newer:

```bash
gh attestation verify MenuBarMijia-<version>.dmg --repo jryang1997/MenuBarMijia
```

The command exits non-zero when the file is not the byte-for-byte artifact built by this repository.

Add `--signer-workflow jryang1997/MenuBarMijia/.github/workflows/release.yml` to also require the `Release` workflow as the signer.

The SBOMs are SPDX 2.3 JSON files:

- `MenuBarMijia-<version>-macos.spdx.json` describes the `.app` bundle inside the DMG, including the bundled `go2rtc`.
- `MenuBarMijia-<version>-windows-x64.spdx.json` describes the npm and Cargo dependency graph of the Windows build together with the EXE and MSI it produced.

Both are generated in the release build with [syft](https://github.com/anchore/syft) and attached next to the installers.

These artifacts do not replace the checks under [Update chain](#update-chain).

The `.sha256` files and the Ed25519 manifest signature remain the checks the app itself enforces before installing an update.

## In scope

A vulnerability is in scope when it is in one of the four areas below.

### Credential storage

macOS keeps the Mi session, the Home Assistant token, AI keys, and the LG webOS client key in one Keychain item (`CredentialVault`).

Windows keeps the Mi session, the Home Assistant token, and AI keys in Credential Manager (`windows/src/core/secureStore.ts`).

A leak of those secrets is in scope.

Storing a Mi `passToken` is in scope.

### Update chain

macOS `UpdateChecker` fetches the latest GitHub release and checks an Ed25519 signature before installation.

Windows checks the same signature.

The app ships the public key.

The private key stays off CI.

The signed payload does not cover the version number.

Builds from before that signature check are outside this area.

### Local services

Camera live view starts a local go2rtc helper bound to `127.0.0.1`.

The Windows app starts the same local bridge, plus a silent ffmpeg helper.

Windows also keeps a host allowlist for its native HTTP client.

A vulnerability in those local helpers, or in that allowlist, is in scope.

### AI action policy

`LocalIntentParser` parses everyday phrases on the device.

`ModelIntentResolver` can send your command, a device catalog, the time, the environment, an active-device summary, and `user_habits` when habit learning is on.

`ModelActionPolicy` holds a low-confidence plan until you confirm it.

It also holds turning a heater on, switching a plug, switching a camera's power, or starting a vacuum, until you confirm.

The `menumijia://` URL scheme asks you to confirm unless `allow_url_direct_control` is set.

Sending data this policy forbids, or skipping a confirmation it requires, is in scope.

## Out of scope

These cases are out of scope.

- Xiaomi cloud, including `account.xiaomi.com` and `api.io.mi.com`. This app is not an official Xiaomi client.
- Upstream Home Assistant.
- Your own network and your own devices.
- A model vendor's own service. A vulnerability in how this app sends data, or in how `ModelActionPolicy` applies a hold, stays in scope.
