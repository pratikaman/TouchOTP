# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TouchOTP is a local macOS menu-bar TOTP authenticator (Swift, AppKit + SwiftUI, no third-party packages). Two entry points: the ⌃⌥⌘O hotkey fills the focused verification-code field after Touch ID, and left-clicking the menu bar icon opens a popover that lists every account and shows all codes after one Touch ID. All seeds live in a single `LARightStore` record behind `.biometryCurrentSet`. It is a development prototype signed with a personal team, not a notarized release. The README is the user-facing document and records per-version behavior changes; update it when behavior changes.

## Commands

```sh
swift test                                                        # all tests (28 core + 28 app)
swift test --filter TouchOTPCoreTests.TouchOTPCoreTests/testRFC6238Vectors   # one test
swift test --filter TouchOTPTests.AccessibilityFocusTests        # one test class
swift test --list-tests

./scripts/build.sh      # xcodegen generate + signed Release xcodebuild → build/TouchOTP.app
./scripts/install.sh    # copies build/TouchOTP.app → ~/Applications (refuses if app is running)

build/TouchOTP.app/Contents/MacOS/TouchOTP --storage-check       # LARightStore round trip with a disposable fixture
build/TouchOTP.app/Contents/MacOS/TouchOTP --render-preview /abs/path.png [--preview-dark] [--preview-compact] [--preview-empty|--preview-import|--preview-review|--preview-complete|--preview-setup|--preview-codes [--preview-locked]]

swift scripts/generate-icon.swift build/TouchOTP.iconset && iconutil -c icns build/TouchOTP.iconset -o Resources/TouchOTP.icns
```

Build facts that matter:

- `swift build` compiles but produces an unprovisioned binary. Anything touching `LARightStore` (import, unlock, update, remove, migrate, `--storage-check`) only works from the signed `.app` produced by `scripts/build.sh`. Under `swift test` the keychain is unavailable, so tests must never reach the store; the vault tests pass only because preview mode, a pending migration, a missing vault, or an unreadable index each throw before the first store call.
- `TouchOTP.xcodeproj` is generated from `project.yml` by XcodeGen and is gitignored. Edit `project.yml`, never the pbxproj. `Package.swift` and `project.yml` both declare the targets and source directories; keep them in sync when adding a source folder or resource.
- Signing team defaults to the personal team in `project.yml` and `scripts/build.sh`; override with `TOUCHOTP_DEVELOPMENT_TEAM`. Keep the bundle ID `local.touchotp.mac` and the same team across upgrades or existing protected records become unreadable.
- Version lives in `Resources/Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`). `FillDiagnostics` reads the short version at runtime.
- `build/` is gitignored scratch: build logs, screenshots, and ad-hoc probe harnesses (`ImportProbe.swift`, `VaultProbe.swift`, `QRProbe.swift`) that were compiled into signed probe apps to exercise the store. Nothing there is source of truth.

## Architecture

Two targets. `TouchOTPCore` is pure Foundation/CryptoKit with no AppKit, so it is fully testable without signing. `TouchOTP` is the app.

### TouchOTPCore (`Sources/TouchOTPCore`)

- `Account.swift`: `OTPSecret` (TOTP generation and parameter validation), `Base32`, `Bindings` (exact HTTPS-hostname and bundle-ID matching plus the validators `canonicalHost` and `validateBundleID`), `AccountRecord` (public metadata, no seed), `ProtectedAccount` (record + secret), and `ProtectedVault` (every `ProtectedAccount`, the unit that is encrypted as one right).
- `Importer.swift`: `OTPImporter.parse` handles `otpauth://totp/...` and Google's `otpauth-migration://offline?data=` via a hand-written, bounded protobuf wire decoder (`Proto`). Version 1 and 2 envelopes are accepted; HOTP and unknown algorithms are rejected. `BatchCollector` assembles multi-QR exports by batch ID and index.

### TouchOTP app (`Sources/TouchOTP`)

The fill pipeline, in order, is the thing to understand first:

1. `GlobalShortcut` (Carbon hotkey, `Target.swift`) or the menu item calls `AppDelegate.fillCurrent` in `Main.swift`.
2. `TargetReader.capture` (`Target.swift`) reads the frontmost app's focused element through Accessibility, using `AccessibilityFocusReader` (`AccessibilityFocus.swift`) which handles Electron's `AXManualAccessibility` opt-in and bounded retries. It requires a text-entry role, an empty value, and for browsers a verified HTTPS URL: Safari and Chromium browsers via an AppleScript allowlist keyed by bundle ID, Firefox and other `http(s)`-handling apps via `AXDocument`, otherwise refused. The focused `AXWebArea` URL must equal the tab URL to exclude embedded frames and the address bar.
3. Matching accounts come from `vault.accounts.filter(target.matches)`. Multiple matches show a non-activating `AccountChooser` panel.
4. `Vault.unlock` calls `unlockAll`, which authorizes the single vault right, decodes `ProtectedVault`, and verifies its records equal the index records as a set, so editing `accounts.json` cannot redirect a code. It then picks the one matching `ProtectedAccount`.
5. `TargetReader.fill` re-captures the target (without re-activating accessibility), compares app, URL, window, and field, then posts one unicode keyboard `CGEvent` to the target PID. It never presses Return, never writes the clipboard, and never activates another app. A focus change at any stage cancels.

Supporting pieces:

- `Vault.swift`: `@MainActor ObservableObject`. The index is `~/Library/Application Support/TouchOTP/accounts.json` (0600, no secrets), encoded as `VaultIndex { vaultID, accounts }`. All seeds sit in one right named `vault-<vaultID>` holding a `ProtectedVault`. Every change goes through `commit`: save a new right under a fresh ID, persist the index, then remove the previous right; an empty vault removes the right entirely. The first import needs no Touch ID; every later import, update or removal calls `unlockAll` first. `beginMutation` serializes mutations and blocks everything when the index failed to load, in preview mode, or while a migration is pending. A bare JSON array in the index is the pre-0.3.0 format (`LegacyIndexEntry`, one `account-<secretID>` right each); a `VaultIndex` may also carry a `legacy` list for a partially completed move. Both surface as `needsMigration` and `legacyAccounts`. `migrateLegacyAccounts` evaluates one `LAContext` and reads each old right through `LegacyKeychain` (Security framework, shared context, so one Touch ID covers all), falls back to `LARight.authorize` per right if that is refused, publishes `migration` progress, and commits whatever was read even when a later step fails. `removeAllAccounts` deletes rights without reading them, for after a fingerprint change.
- `LegacyKeychain.swift`: the only place that bypasses `LARightStore`. It documents the observed item layout (generic-password item named `com.apple.LocalAuthentication:Authorization:<id>` holding an ECIES envelope, Secure Enclave key with the same application tag carrying the biometry constraint). Migration only; normal reads and writes stay on `LARightStore`. `--keychain-probe` prints attributes to re-verify the layout on a new OS. `storageCheck` and `biometricCheck` are the self-test entry points. `Vault(indexFile:)` exists so tests can point at a temp file.
- `CodeListView.swift`: the menu bar popover. `CodeListModel` holds the decrypted `ProtectedAccount`s only while unlocked (auto-lock after 90 s, on popover close, on app resign), `CodeListView`/`CodeRow` render codes from a `TimelineView` tick, and `MigrationPanel` is shown in both the popover and the manager window until legacy records are moved. In `Main.swift`, left-click toggles the `NSPopover` (activating the app), right-click shows the classic `NSMenu` without activating so "Fill current field" still targets the front app, `popoverShouldClose` returns false while Touch ID is up, and closing the popover hides the app when no other window is open.
- `OpenVPNChallenge.swift`: the only exception to "refuse masked fields." Accepts a secure text field only for bundle `org.openvpn.client.app` when the enclosing small dialog has the English "Multi-factor authentication" title, an authenticator/verification-code prompt, and exactly one text input. It deliberately never reads input values.
- `FillDiagnostics.swift`: writes `last-fill-diagnostic.json` with stage, outcome, and boolean comparisons only. Do not add fields for codes, names, URLs, or UI text.
- `DestinationDraft.swift`: UI-side draft of `Bindings`; reduces pasted login URLs to their hostname and rejects duplicates. Saving goes through `Vault.update` with Touch ID.
- Views: `Views.swift` holds `ManagerView` (NavigationSplitView with search) and `AccountDetail` (code reveal with countdown, destination rows, save/revert bar, unsaved-changes guard). `ImportView.swift` is the scan → review → complete flow using `CameraScanner`/`QRImageReader` from `Camera.swift` (AVFoundation + Vision). `SetupView.swift` is the Autofill setup sheet. `UIComponents.swift` has shared styling and `NativeAppPresentation` for app name/icon lookup.
- `PreviewSupport.swift` supplies synthetic accounts (a stored `static let`, so IDs stay stable within a process) and synthetic `ProtectedAccount`s for `--render-preview`; `Vault(previewAccounts:)` must never reach `LARightStore`.

## Testing conventions

- `Tests/TouchOTPCoreTests`: RFC 6238/4226 vectors, Base32, importer (including synthetic v2 Google exports and fuzzed protobuf), host/bundle-ID validation and phishing cases.
- `Tests/TouchOTPTests` uses `@testable import TouchOTP`. Accessibility tests inject an `AccessibilityAccess` struct of closures and use inert handles from `AXUIElementCreateApplication(fakePID)`, so no Accessibility permission, other app, or Touch ID is needed. Follow that pattern for any new AX logic rather than touching real AX APIs in tests.
- Vault tests (`VaultIndexTests`, `PreviewVaultTests`, `CodeListModelTests`) construct `Vault(indexFile:)` against a temp directory or `Vault(previewAccounts:)`, and only exercise paths that throw before any `LARightStore` call. A test that would save or read a right cannot run under `swift test`.
- Live camera, Touch ID, and real browser/app filling are manual checks listed in the README's Validation section. When changing fill behavior, update that list and the version notes.

## Invariants to preserve when editing

- Website destinations are exact HTTPS hostnames on port 443. No wildcards, subdomain inheritance, paths, or HTTP. Account names never authorize a host.
- Browser URLs are trusted only from the static Safari/Chromium allowlists or an `AXDocument` attribute; everything else is refused rather than treated as a native app.
- Secure/masked fields are refused except via `OpenVPNChallenge`.
- The decrypted vault exists in memory only for the current vault operation or inside `CodeListModel` while the popover is open. Autofill never reuses the popover's unlocked copy; it always runs its own Touch ID with an account-and-destination reason.
- Nothing in the index may be trusted until it matches the protected copy. Keep `commit` ordering (save new right, persist index, remove old right) so a crash never leaves an index pointing at a missing right.
- The app is `LSUIElement` with `.accessory` activation policy; the window closes to the menu bar.
- No network, analytics, clipboard, or screen capture. Camera frames and import payloads stay in memory.
