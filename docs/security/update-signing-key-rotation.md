# Update-signing key rotation and revocation

This runbook covers the Ed25519 key that signs the in-app update manifest on macOS and Windows.

It does not cover the macOS code-signing certificate pinned by `MijiaCodeSignCertSHA1`, or the Windows Authenticode certificate. Those are separate trust anchors; see [ADR-0005](../adr/0005-update-signing-trust-chain.md).

## 1. Key identity, storage, and coverage

### 1.1 Algorithm and encoding

- **Signature algorithm:** Ed25519.
  - macOS verifies with CryptoKit `Curve25519.Signing` in `UpdateSignature.verify`.
  - Windows verifies with `ring::signature::ED25519` in `verify_ed25519_signature`.
- **Private key:** a 32-byte Ed25519 seed.
- **Public key:** the 32-byte raw public key, base64-encoded (44 characters).
- **`key_id`:** the full base64 public key string, not a short fingerprint. `UpdateManifest.parse` requires it as a non-optional string, and `UpdateManifest.accept` compares it byte-for-byte with the key that verified the signature.

`scripts/sign_update.swift` accepts the private key in either form:

1. Base64 of the 32-byte raw seed (recommended).
2. A PKCS#8 PEM private key; `decodeSeed` takes the last 32 bytes of the DER payload.

### 1.2 Where the private key is stored

The private key is **never in this repository, a release asset, or CI**.

`scripts/sign_update.swift` reads it from:

1. the environment variable `MENUBARMIJIA_UPDATE_SIGNING_KEY`, if set;
2. otherwise the login Keychain generic password:
   - service `com.jryang1997.release-signing.ed25519`
   - account `update-seed-base64`

Read the Keychain copy with:

```bash
security find-generic-password \
  -s com.jryang1997.release-signing.ed25519 \
  -a update-seed-base64 \
  -w
```

Store or replace it with:

```bash
security add-generic-password -U \
  -s com.jryang1997.release-signing.ed25519 \
  -a update-seed-base64 \
  -w '<base64-seed>'
```

Keep at least one offline backup outside the signing machine. Losing every copy is a key-loss event; see §4.4.

`.github/workflows/release.yml` and `.github/workflows/finalize.yml` only print the offline signing command. Neither reads `MENUBARMIJIA_UPDATE_SIGNING_KEY`, and no repository secret contains it.

### 1.3 What the signature covers

`scripts/sign_update.swift` signs the exact bytes of:

```
MenuBarMijia-<version>.update.json
```

and writes a detached base64 signature plus a trailing newline to:

```
MenuBarMijia-<version>.update.json.ed25519.sig
```

The manifest is produced by `scripts/update_manifest.py canonical_bytes`: one-line JSON with the keys in this order and exactly three `files` entries.

| Field | Meaning | Enforced by |
| --- | --- | --- |
| `version` | The release this manifest belongs to; must equal the release being installed | `UpdateManifest.accept` (`releaseVersionMismatch`), `accept_update_manifest` (`ReleaseVersionMismatch`) |
| `min_from` | Lowest running version allowed to install this release | `belowMinimum` / `BelowMinimum`; must be `<= version` at parse time |
| `key_id` | Base64 public key that signed this manifest | `keyIDMismatch` / `KeyIdMismatch` |
| `files[0]` | `platform: "macos"`, DMG file name, SHA-256 | exact name/order, lowercase 64-hex digest |
| `files[1]` | `platform: "windows"`, EXE file name, SHA-256 | same |
| `files[2]` | `platform: "windows"`, MSI file name, SHA-256 | same |

The signature covers the whole manifest, so changing any field invalidates it. The package bytes are not signed directly; the signed SHA-256 entries bind them. `UpdateManifest.accept` also rejects a manifest whose signed `version` does not match the release tag, which closes the replay path fixed in PR #198.

### 1.4 Where the public keys live

The trust set is compiled into each client. There is no fetched key list and no key expiry.

| Location | Symbol | Role |
| --- | --- | --- |
| `Sources/MijiaCore/UpdateChecker.swift` | `updateSigningPublicKeyBase64` | Current signing key (primary) |
| `Sources/MijiaCore/UpdateChecker.swift` | `updateSigningOverlapPublicKeyBase64` | Optional second key trusted during rotation; empty when unused |
| `Sources/MijiaCore/UpdateChecker.swift` | `updateSigningPublicKeysBase64` | Trust set passed to `UpdateManifest.accept`; primary first, empty overlap filtered out |
| `Sources/MijiaCore/UpdateManifest.swift` | `UpdateManifest.accept(trustedPublicKeysBase64:...)` | Verifies against every trusted key and requires `key_id` to name the key that verified |
| `windows/src-tauri/src/main.rs` | `UPDATE_SIGNING_PUBLIC_KEY_BASE64`, `UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64`, `update_signing_public_keys()` | Windows trust set |
| `windows/src-tauri/src/update_manifest.rs` | `accept_update_manifest(trusted_public_keys_base64:...)` | Windows verification |
| `windows/src/core/updateChecker.ts` | `UPDATE_SIGNING_PUBLIC_KEY_BASE64` | Frontend copy of the primary key; asset selection only, verification happens in Rust |
| `scripts/sign_update.swift` | `expectedPublicKeyBase64` | Refuses to sign unless the private key matches the **primary** key |
| `scripts/update_manifest.py` | `public_key()` | Reads the primary key from `UpdateChecker.swift` and writes it as `key_id` |
| `scripts/check_release.sh` | `verify_ed25519_file` | Reads the primary key from `UpdateChecker.swift` and verifies the manifest with `openssl pkeyutl` |
| `scripts/check.sh` | Ed25519 block | Fails unless the primary key is identical in all four source files, the overlap key is identical in both platform files, and any non-empty overlap key is valid 32-byte base64 distinct from the primary |
| `scripts/testdata/MenuBarMijia-1.1.7.update.json` | `scripts/update_manifest.py self-test` golden | Hard-codes the primary `key_id`; must be re-keyed whenever the primary changes |

`check.sh --lint-only` is the single command that proves these copies agree.

### 1.5 Client behavior

macOS `AppUpdater.stageUpdate` order:

1. download the package;
2. fetch the manifest and `.update.json.ed25519.sig`;
3. call `UpdateManifest.accept`;
4. only then unpack, validate the bundle ID/version, handle quarantine, and verify code signing.

Windows `accept_update_manifest` runs after the manifest, signature, and installer bytes are downloaded, and before the installer is written to `%TEMP%` or launched elevated. The TypeScript updater only selects the expected asset names and download URLs.

A verification failure is fail-closed: macOS throws an `UpdateInstallError` and deletes the staging directory; Windows returns the failure message and does not launch an installer. Relevant mappings:

| Manifest failure | macOS error | Windows message |
| --- | --- | --- |
| missing signature | `updateSignatureMissing` | missing-signature text |
| invalid/malformed signature or manifest | `updateSignatureInvalid` | invalid-signature text |
| `key_id` not trusted or not the verifier | `updateSignatureInvalid("update manifest key id does not match")` | invalid-signature text (`KeyIdMismatch`) |
| signed version differs from the release | `updateSignatureInvalid("update manifest is signed for a different version")` | invalid-signature text (`ReleaseVersionMismatch`) |
| running version at or above signed version | `updateSignatureInvalid("update manifest is not newer than the installed version")` | invalid-signature text (`NotNewer`) |
| running version below `min_from` | `updateBelowMinimum` | below-minimum text |
| package not listed | `updateSignatureInvalid("update package is not listed in the manifest")` | invalid-signature text (`UnexpectedPackage`) |
| package hash differs | `checksumMismatch` | hash-mismatch text |

## 2. Trust model and the rotation invariant

The trust set is the non-empty entries of:

```
[updateSigningPublicKeyBase64, updateSigningOverlapPublicKeyBase64]
```

on macOS and the same two constants on Windows. At most two keys are trusted at once.

`accept` requires both:

1. the detached signature verifies under at least one trusted key; and
2. `key_id` equals one of the keys that actually verified.

The second rule prevents a manifest from naming one trusted key while being signed by the other.

Consequences:

- Clients accept a signature from either key, but release tooling only signs with the **primary**: `scripts/sign_update.swift` refuses any seed whose public key is not `expectedPublicKeyBase64`, and `check.sh` pins that constant to the primary. The overlap key exists so a release built with the new primary is verifiable by clients that provisioned it, and so an old-key-signed rollback is still accepted during the overlap window.
- Release tooling (`update_manifest.py`, `sign_update.swift`, `check_release.sh`) always uses the **primary** key. During cutover, the primary constant is changed to the new key before that release is built and signed.
- A new key cannot protect a release until clients already trust it. **The signing key for release N must already be compiled into the client version that installs N.** Therefore every rotation needs a provisioning release signed by a currently trusted key.
- There is no signed key list, no key expiry, and no revocation feed. Removing a key from the compiled trust set in a newer release is the revocation mechanism.
- Clients released before this multi-key change trust exactly one key. They cannot follow a cutover automatically; they must install the cutover release manually once.

## 3. Normal rotation

Use this when the current key is healthy and you want to replace it (routine hygiene, algorithm policy, or preparing for a suspected-but-unconfirmed exposure).

Preconditions:

- access to the signing machine and the offline private-key backup;
- the ability to publish at least two releases;
- no active key-compromise incident; if one is active, use §4 instead.

Names used below:

- `K_old`: current `updateSigningPublicKeyBase64`.
- `K_new`: the new key.
- `R1`: provisioning release.
- `R2`: cutover release.
- `R3`: retirement release.

### Step 0 — Generate and store `K_new`

Run this on the offline/signing machine:

```bash
swift -e 'import CryptoKit; let k = Curve25519.Signing.PrivateKey(); print("private:", k.rawRepresentation.base64EncodedString()); print("public:", k.publicKey.rawRepresentation.base64EncodedString())'
```

Record:

- the public key verbatim (this is `key_id`);
- where the offline seed backup is stored;
- who generated it and when, in the rotation PR or incident record.

Do **not** commit the private line. Do not paste it into a release note, issue, or CI log.

The Keychain item can only hold one seed at a time. During the overlap you may keep `K_old` in the Keychain and pass `K_new` through the environment variable, or swap the Keychain item at cutover after `R1` is signed.

### Step 1 — Provisioning release `R1` (signed by `K_old`)

Edit only the overlap constants; the primary stays `K_old`:

1. `Sources/MijiaCore/UpdateChecker.swift`:
   ```swift
   public static let updateSigningOverlapPublicKeyBase64 = "<K_new>"
   ```
2. `windows/src-tauri/src/main.rs`:
   ```rust
   const UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64: &str = "<K_new>";
   ```

Do not change `expectedPublicKeyBase64`, `UPDATE_SIGNING_PUBLIC_KEY_BASE64`, or the golden manifest for `R1`.

Run:

```bash
bash scripts/check.sh --skip-snapshots
```

Ship `R1` through the normal pipeline: tag, draft build, offline signature with `K_old`, upload the manifest and `.update.json.ed25519.sig`, then Finalize Release.

Verify before publishing:

```bash
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["key_id"])' \
  dist/MenuBarMijia-<R1>.update.json
# must print K_old

bash scripts/check_release.sh assets <R1> dist
```

Client effect: a client that installs `R1` now trusts `{K_old, K_new}`. Clients older than `R1` still trust only `K_old`.

**Overlap window.** The code imposes no minimum. Because the project has no install telemetry, there is no way to prove that active users passed through `R1`. Recommended minimum: keep `R1` as the Latest release for at least one full release cycle and 30 days. Proceed to Step 2 only when you accept that clients older than `R1` will have to install `R2` manually.

### Step 2 — Cutover release `R2` (signed by `K_new`)

Change all trust-set copies at once:

1. `Sources/MijiaCore/UpdateChecker.swift`:
   - `updateSigningPublicKeyBase64 = "<K_new>"`
   - `updateSigningOverlapPublicKeyBase64 = "<K_old>"` (keep the old key for the rollback window)
2. `scripts/sign_update.swift`: `expectedPublicKeyBase64 = "<K_new>"`
3. `windows/src/core/updateChecker.ts`: `UPDATE_SIGNING_PUBLIC_KEY_BASE64 = "<K_new>"`
4. `windows/src-tauri/src/main.rs`:
   - `UPDATE_SIGNING_PUBLIC_KEY_BASE64 = "<K_new>"`
   - `UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64 = "<K_old>"`
5. `scripts/testdata/MenuBarMijia-1.1.7.update.json`: replace its `key_id` value with `<K_new>`. The golden is a fixed 526-byte fixture; the base64 key length is unchanged, so only that value changes. `scripts/update_manifest.py self-test` fails until this is done.

Run:

```bash
bash scripts/check.sh --skip-snapshots
```

Ship `R2` with the private key for `K_new`:

```bash
MENUBARMIJIA_UPDATE_SIGNING_KEY='<K_new seed>' \
  swift scripts/sign_update.swift --min-from <floor> \
  dist/MenuBarMijia-<R2>.dmg \
  dist/MenuBarMijia-<R2>-windows-x64-setup.exe \
  dist/MenuBarMijia-<R2>-windows-x64.msi
```

`sign_update.swift` refuses to continue unless the seed's public key equals the new primary (`keyMismatch`), and prints the public key it used.

Verify:

```bash
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["key_id"])' \
  dist/MenuBarMijia-<R2>.update.json
# must print K_new

bash scripts/check_release.sh assets <R2> dist
```

Client effect:

- clients that installed `R1` or later accept `R2` (both keys are trusted);
- clients older than `R1` reject `R2` with a signature/key-id failure and must install it manually;
- after installing `R2`, clients trust `{K_new, K_old}`.

**`min_from` is not a force-update lever.** It only rejects a client whose running version is below the floor, and signature/key-id checks run before the floor check. Setting `min_from` above pre-`R1` versions does not push those clients forward; they fail earlier because they do not trust `K_new`. Set `min_from` to the oldest version you still intend to serve, and document the manual-install path for older clients in the release notes.

### Step 3 — Retirement release `R3` (signed by `K_new`)

After the rollback window:

1. set `updateSigningOverlapPublicKeyBase64` and `UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64` to `""`;
2. keep `K_new` as primary;
3. run `bash scripts/check.sh --skip-snapshots`;
4. ship `R3` signed by `K_new`.

After `R3`, `K_old` is no longer trusted by updated clients and cannot be used for rollback. Keep the seed archived only for incident forensics; do not sign with it again.

### Rollback

| Point | Rollback action |
| --- | --- |
| Before `R1` is published | Clear the overlap constants and abandon the rotation. No client changed trust. |
| After `R1`, before `R2` | Set the overlap back to `""` in a newer release signed by `K_old`. Clients that installed `R1` still accept `K_old`; clients that did not are unaffected. |
| After `R2`, before `R3` | Set primary back to `K_old`, overlap to `""` (or `K_new` if only `K_new`'s release was bad and you want to retry), bump the version above `R2`, and sign with `K_old`. Clients on `R1`/`R2` trust `K_old`. |
| After `R3` | `K_old` is no longer trusted. Roll forward with `K_new`; if `K_new` is lost, every client needs a manual install of a build signed by a key you still hold. |

A rollback is a normal release: the version must be higher than the release being withdrawn, and `scripts/check.sh` must pass with the reordered constants.

## 4. Compromise and revocation

There is no online revocation list and no key expiry. "Revoking" a key means:

1. stop signing with it;
2. remove it from the compiled trust set in a release signed by a trusted successor;
3. publish an out-of-band advisory telling users what to do.

Revocation is only effective for clients that install the release that removes the key. Clients that never update remain exposed; the advisory is the only mitigation for them.

### 4.1 Current signing key compromised, successor already provisioned (`R1` shipped)

This is the recoverable case: clients that installed `R1` already trust `K_new`.

1. Stop publishing. Preserve logs, release drafts, and the compromised machine's state for forensics.
2. Build the emergency release with:
   - `updateSigningPublicKeyBase64 = "<K_new>"`
   - `updateSigningOverlapPublicKeyBase64 = ""` (**do not** keep the compromised key)
   - the same changes in the Windows files, `sign_update.swift`, the TypeScript constant, and the golden manifest;
3. run `bash scripts/check.sh --skip-snapshots`;
4. sign with `K_new`, upload, Finalize;
5. publish the advisory (see §4.5), then publish the release notes.

Effect: clients on `R1` or later update securely to a build that no longer trusts the compromised key. Clients older than `R1` cannot verify the emergency release and must install it manually; until they do, they still trust the compromised key.

Do not keep the compromised key in the overlap "for compatibility". Any client that still trusts it can be served a malicious manifest signed with it.

### 4.2 Current signing key compromised, no successor provisioned

There is no release that existing clients can verify. This is the catastrophic case.

1. Do not publish anything signed with the compromised key.
2. Generate `K_new` offline.
3. Build a release with `K_new` as primary and no overlap.
4. Publish the release and an advisory that states plainly that the in-app updater cannot verify this build on older clients and that a manual install is required.
5. Publish package SHA-256 values and the public key through the advisory, and ask users to verify them through a second channel (repository advisory page, release page, project social account).

The implementation cannot distinguish a malicious manifest signed by the compromised key from a legitimate one. Only users who replace their install manually leave the compromised trust set.

### 4.3 Overlap key compromised before cutover

`K_new` has not signed a published release yet.

1. Set both overlap constants back to `""`.
2. Ship a release signed by `K_old` (or simply stop using `K_new` and keep the current release).
3. No advisory is required for clients because no published release trusted `K_new`; record the event in the rotation log anyway.

If a release was signed with the compromised overlap key outside the normal tooling, treat it as §4.1/§4.2 depending on which key the clients trust.

### 4.4 Current key lost (not compromised)

- If `R1` has shipped and clients trust `K_new`, continue the normal cutover with `K_new`; keep the archived `K_old` only for the rollback window.
- If `R1` has not shipped, no existing client can verify a `K_new` release. Follow §4.2: manual install for everyone.
- If both the only copy of `K_old` and the only copy of `K_new` are lost, no further signed release is possible; users must install a build signed by a newly generated key manually.

Losing a key is not a compromise, but the remediation path is the same because old clients cannot learn a new key without a trusted release.

### 4.5 Out-of-band advisory

Publish through every channel the project controls, not only in the release notes:

1. **GitHub Security Advisory** in the repository Security tab (private while the fix is prepared, then public).
2. **Release notes** for the fixed release, linking the advisory.
3. **Pinned GitHub issue** with the same facts.
4. Any project social account used for announcements.

There is no mailing list and no in-app advisory channel; state that in the advisory if users ask.

Include:

- affected versions and which key is affected (public key string);
- fixed version and the new public key;
- what the attacker could do and what they could not do;
- manual install steps for macOS and Windows;
- SHA-256 values for the packages and how to verify them;
- timeline and credit, if applicable.

Never include the private seed, PKCS#8 PEM, or Keychain contents.

### 4.6 Force-update floor: not supported

There is no force-update field in the manifest and no remote kill switch. `min_from` only refuses an update when the running version is below it; it cannot make a client update. Raising it during a revocation would block updates for old clients without protecting them.

If a future incident needs "clients below X must update before anything else", that requires a code change (a signed minimum-secure-version field with defined client behavior), not a documentation change. This is recorded as a follow-up in §6.

### 4.7 User remediation

macOS:

1. Download the DMG from the release linked in the advisory.
2. Verify the hash:
   ```bash
   shasum -a 256 MenuBarMijia-<version>.dmg
   cat MenuBarMijia-<version>.dmg.sha256
   ```
3. Open the DMG, drag `MenuBarMijia` to `/Applications`, and replace the existing copy.
4. The in-app updater on an old client will keep failing closed until the app is replaced; that is expected.

Windows:

1. Download the EXE or MSI from the release linked in the advisory.
2. Verify the hash:
   ```powershell
   Get-FileHash -Algorithm SHA256 .\MenuBarMijia-<version>-windows-x64-setup.exe
   ```
   Compare with the `.sha256` asset.
3. Run the installer.

For users who want to verify the manifest rather than only the package hash, point them at §5.4.

## 5. Verification commands

### 5.1 Key parity and golden manifest

```bash
bash scripts/check.sh --lint-only
```

This checks the primary key is identical in `UpdateChecker.swift`, `sign_update.swift`, `updateChecker.ts`, and `main.rs`; that the overlap key is identical in both platform files and is valid 32-byte base64 distinct from the primary; and that `scripts/update_manifest.py self-test` passes.

### 5.2 Swift behavior

```bash
swift test --filter UpdateManifestTests
swift test --filter UpdateCheckerTests
bash scripts/check.sh --skip-snapshots
```

`UpdateManifestTests` covers overlap-key acceptance, untrusted keys, and the rule that `key_id` must name the key that actually verified. `UpdateCheckerTests` exercises `AppUpdater.stageUpdate` end to end.

### 5.3 Windows behavior

```bash
npm test --prefix windows
npm run typecheck --prefix windows
```

Rust tests for `update_manifest.rs` and the key helper run in Windows CI (`cargo test` under `windows/src-tauri`). They are not part of the macOS local gate.

### 5.4 Release gate

Collect exactly the eight published assets into one directory and run:

```bash
bash scripts/check_release.sh assets <version> <dir>
```

It requires `openssl` and `python3`. It:

- extracts `updateSigningPublicKeyBase64` from the checked-out `Sources/MijiaCore/UpdateChecker.swift`;
- wraps the raw 32-byte key in an Ed25519 SubjectPublicKeyInfo DER;
- runs `openssl pkeyutl -verify -pubin -inkey ... -rawin` against the manifest;
- checks the manifest fields against the three packages and their `.sha256` sidecars.

Finalize Release checks out the tag, so the key it verifies with is the key compiled into that release.

### 5.5 Inspect the manifest key

```bash
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["key_id"])' \
  dist/MenuBarMijia-<version>.update.json
```

Compare the output with:

```bash
python3 - <<'PY'
import pathlib
import re
source = pathlib.Path("Sources/MijiaCore/UpdateChecker.swift").read_text()
print(re.search(r'updateSigningPublicKeyBase64\s*=\s*"([^"]+)"', source).group(1))
print(re.search(r'updateSigningOverlapPublicKeyBase64\s*=\s*"([^"]*)"', source).group(1))
PY
```

The manifest `key_id` must equal the primary key compiled at the signed tag. `scripts/sign_update.swift` refuses to sign with any other key, so a normal release should never show the overlap key here. If it does, the signature was produced outside the documented tooling and should be treated as an incident.

### 5.6 Audit trail for a rotation PR

Record in the PR or incident record:

- [ ] old and new public keys, verbatim;
- [ ] who generated the new key, when, and where the offline backup is stored;
- [ ] the output of `bash scripts/check.sh --lint-only`;
- [ ] the release tags/paths for `R1`, `R2`, and `R3` (or the emergency release);
- [ ] the manifest `key_id` for each release;
- [ ] the advisory URL, for any revocation;
- [ ] confirmation that no private key material appears in the diff, CI logs, or release assets.

## 6. Code gaps and follow-ups

This change added multi-key trust, so the normal rotation above is executable without a protocol change. The remaining gaps are explicit:

| Gap | Impact | Next step |
| --- | --- | --- |
| Trust set is two compile-time constants; there is no signed key list and no arbitrary key count | Every rotation needs a provisioning release; a compromised key cannot be revoked without clients installing a newer release | Consider a signed `keys` array or key-list document only if rotations become frequent; it would need its own replay/rollback analysis |
| No forced update or minimum-secure-version field | A compromised key remains trusted by clients that never install the revocation release | Add a signed policy field with defined client behavior if a force-update requirement appears |
| No telemetry or attestation of installed trust sets | The overlap window cannot be measured; the runbook uses time/release-count judgment | Optional privacy-preserving adoption metric, or accept the manual-install tail |
| Clients before the multi-key release trust exactly one key | The first rotation still needs one manual install for clients older than the provisioning release | Document in release notes; unavoidable without a previously shipped second key |
| Golden manifest hard-codes `key_id` | `scripts/update_manifest.py self-test` fails after a primary change until the fixture is re-keyed | Already enforced by `check.sh --lint-only`; update the fixture in the cutover PR |
| Windows frontend constant is not used for verification | No security impact; Rust is the enforcement point | Keep the copy for parity; `check.sh` already checks it |
| Private key is stored as a file/Keychain item, not an HSM | Signing-machine compromise exposes the key | Move to a hardware-backed key or an offline signing machine policy if the project grows |

## 7. References

- `Sources/MijiaCore/UpdateChecker.swift` — `updateSigningPublicKeyBase64`, `updateSigningOverlapPublicKeyBase64`, `updateSigningPublicKeysBase64`, `AppUpdater.stageUpdate`
- `Sources/MijiaCore/UpdateManifest.swift` — `UpdateManifest.accept`
- `Sources/MijiaCore/UpdateSignature.swift` — `UpdateSignature.verify`
- `scripts/sign_update.swift` — offline manifest signer
- `scripts/update_manifest.py` — canonical manifest encoder, `self-test`, `check-fields`
- `scripts/check_release.sh` — release asset and Ed25519 checks
- `scripts/check.sh` — key parity lint
- `.github/workflows/release.yml`, `.github/workflows/finalize.yml` — draft and finalize gates
- `windows/src-tauri/src/update_manifest.rs`, `windows/src-tauri/src/main.rs` — Windows verification
- [ADR-0005](../adr/0005-update-signing-trust-chain.md) — original trust-chain decision
