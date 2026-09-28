# Repository Guidelines

Contributor guide for **MacPilot**, a native macOS menu-bar app (Swift 6, SwiftPM, macOS 14+) with 18 independently switchable feature modules: app inactivity rules, scheduled launch, Awake keep-awake, BLE proximity lock/unlock, iPhone remote control, capture/screenshot tooling, dock groups, local ports, and more.

## Project Structure & Module Organization

- `Sources/MacPilot/` — main executable target, one subdirectory per feature cluster (`Awake/`, `BLE/`, `DockGroups/`, `RemoteControl/`, `SnapzyCapture/`, `SmoothScrolling/`, …) plus `MacPilotApp.swift` (core), `BLEUnlock.swift` (proximity lock/unlock), and `SoftwareUpdate.swift` (release checks, validation, and update orchestration).
- `Packages/MacPilotRemoteProtocol/` — local SwiftPM package with the wire protocol + transport shared by the macOS app and the iOS remote app.
- `iOS/MacPilotRemote/` — companion iPhone app (Xcode project generated from `project.yml`; build scripts inside).
- `website/` — Chinese product site (Vinext/React, deployed to Cloudflare); Node ≥ 22.13, its own `package.json` and lint setup.
- `Sources/MacPilotUpdater/` + `MacPilotUpdaterSupport/` — helper executable that atomically replaces the verified app bundle and relaunches it after the main process exits.
- Other packaged targets: `MacPilotDockGroupsCore` + `MacPilotDockHelper`, `MacPilotLocalPortsCore`, `MacPilotPowerIPC` + `MacPilotPowerHelper`, `MacPilotRightClickKit` + `MacPilotFinderSync`, `MacPilotOcclusionPatch` (dynamic library). See Architecture boundaries below.
- `Tests/` — Swift Testing targets: `MacPilotTests` (main suites, e.g. `LaunchRuleCodingTests.swift`, `BLEUnlockPerformanceTests.swift`, `SoftwareUpdateTests.swift`), plus `MacPilotFinderSyncTests`, `MacPilotLocalPortsCoreTests`, `MacPilotRightClickKitTests`, `MacPilotUpdaterSupportTests`. `Tests/Performance/` holds resource-acceptance benchmarks (`resource-benchmark.sh`, thresholds in its README).
- `Resources/` — `Info.plist`, `MacPilot.entitlements`, `AppIcon.icns`, icon sources.
- `Scripts/` — `build-app.sh`, `build-findersync.sh`, `distribute-app.sh`, `version.sh`, `signing-requirement.sh` / `verify-signing-requirement.sh`, `measure-memory.sh`, `capture-permission-diagnostics.sh`, `verify-awdl.sh`.
- `docs/` — `UI_DESIGN.md` (normative UI tokens), `REMOTE_CONTROL.md` (iPhone→Mac design, wire protocol, security model), `AWAKE_MANUAL_TESTS.md` (manual power-state acceptance), `PERMISSION_DIAGNOSTICS.md`, `UPDATE_DOWNLOADS.md`, `MEMORY_REVIEW.md`.
- `.github/workflows/build.yml` — CI.
- Runtime config lives outside the bundle at `~/Library/Application Support/MacPilot/config.json`; bundle ID `com.misswell.macpilot`.

## Architecture boundaries

- `MacPilotLocalPortsCore` stays plain Foundation/Darwin on purpose — no SwiftUI or app-model dependency, so a future CLI can reuse the same identity boundary.
- `MacPilotPowerIPC` contains only types and pure logic, never privileged operations; `MacPilotPowerHelper` is the root LaunchDaemon that provides the `pmset disablesleep` capability.
- Dock Groups share one model via `MacPilotDockGroupsCore`: the main app writes config, the helper reads it, tests verify integrity. Every group's helper app reuses a single binary, differentiated only by bundle ID, icon, and name — never touch third-party apps outside that shared model.
- `MacPilotFinderSync` uses the `_NSExtensionMain` entry point (built via `Scripts/build-findersync.sh`); SwiftUI is linked explicitly so SwiftUICore reaches the linker through SwiftUI's re-export instead of an autolink entry.

## Build, Test, and Development Commands

- `swift build` — compile (debug).
- `swift test` — run all tests; filter with `swift test --filter SuiteName.method`.
- `./Scripts/version.sh` — print current version (latest `v*` tag + commits since).
- `./Scripts/build-app.sh` — release build, package `MacPilot.app`, inject version into `Info.plist`, codesign (Developer ID if `MACPILOT_DEVELOPER_ID` is set, otherwise ad-hoc; the old `OCTOPILOT_DEVELOPER_ID` alias remains accepted).
- `./Scripts/distribute-app.sh` — sign with Hardened Runtime, notarize, staple, output `MacPilot-<version>-macos.zip` (needs Apple Developer credentials).
- `website/` (run inside that directory): `npm ci`, `npm run dev`, `npm run build`, `npm run lint` (oxlint).

## Coding Style & Naming Conventions

- Swift, 4-space indentation. No committed formatter or linter; match surrounding style.
- Types `UpperCamelCase`, members `lowerCamelCase`. Test methods are behavioral phrases (`closeWindowsModeUsesBehaviorBasedName`).
- Route user-facing strings through `AppText.value(_:language:)`, keeping `.simplifiedChinese` and `.english` entries in sync.

## UI Design Standards

- All feature pages MUST follow the unified UI language (native sidebar + 30pt header + adaptive-glass `SettingsCard`). macOS 26 uses Liquid Glass and macOS 15–25 uses the documented material fallback. Read `docs/UI_DESIGN.md` before adding or modifying any UI, and run its new-feature checklist before submitting.
- Reuse `SettingsCard` (`Sources/MacPilot/SettingsUI.swift`) in the main module and `RightClickSettingsCard` (`Sources/MacPilotRightClickKit/Settings/RightClickSettingsCard.swift`) in the Kit — never write an ad-hoc card style.
- The design tokens (margins 36/34/30, card spacing 24, adaptive corner radius/material, etc.) are normative in `docs/UI_DESIGN.md`; do not deviate.

## Testing Guidelines

- Framework: **Swift Testing** (`import Testing`; `@Test`, `#expect`, `#require`). Suites are `struct`s of `@testable import MacPilot` functions.
- Name tests as sentences describing the invariant. Use `UserDefaults(suiteName:)` with a UUID for stateful tests and clean up via `defer`.
- Run `swift test` before pushing.
- Power/display-state behavior (Awake, closed-lid sleep) can't be fully automated: follow the scenarios in `docs/AWAKE_MANUAL_TESTS.md` when changing it. Memory/resource acceptance thresholds live in `Tests/Performance/README.md` and `docs/MEMORY_REVIEW.md`.
- Before tagging a release, also run a fresh release build with `-Xswiftc -warnings-as-errors`. GitHub's macOS runner may promote Swift concurrency diagnostics that are only warnings in a cached local build.

## Commit & Pull Request Guidelines

- Use **Conventional Commits**: `feat:`, `fix:`, `refactor:`, `docs:` (e.g. `feat: add BLE proximity lock`). Imperative subject, ≤72 chars.
- PRs target `main`. Describe what and why, link issues, and call out Accessibility/Bluetooth behavior changes.
- CI builds, packages, and verifies the signature on every push/PR — do not merge if `build` fails.
- Version tags `v<major>.<minor>.<patch>` trigger the `dist` job and a GitHub Release.
- Push the release commit to `main` before creating the version tag. Never move or overwrite an already-pushed version tag; publish a new patch version for release fixes.
- A pushed tag is not proof of a published release. Verify the Actions `dist` job and `gh release view <tag>` both succeed, and confirm the ZIP asset is present.

## Content Publishing

- When publishing articles about this project to external platforms (Zhihu, Cnblogs, Juejin, CSDN, SegmentFault, sspai, etc.), write in a natural first-person developer voice — avoid template-y, marketing-style phrasing.
- Do NOT check any 「内容由AI生成」 / AI-generated declaration checkbox on those platforms.
- Reusable article drafts live in `~/Documents/MacPilot-Articles/` (`macpilot-intro.md` full version, `macpilot-human.md` first-person version, platform variants).

## Security & Signing

- `MacPilot.entitlements` enables only `com.apple.security.cs.disable-library-validation` — do not add entitlements without justification.
- The BLE unlock login password lives in **Keychain**; never log it or persist it to `config.json`.
- Accessibility and Bluetooth are required at runtime; Close Windows mode prompts for Accessibility. Ad-hoc local builds may re-prompt Accessibility each rebuild — distribute with a stable Developer ID to preserve grants.
- The tag workflow requires exactly six Actions secrets: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_DEVELOPER_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`.
- `APPLE_ID` is the Apple Developer login email; `APPLE_APP_SPECIFIC_PASSWORD` is generated at account.apple.com. Never paste an app-specific password into chat or a command argument; revoke it immediately if exposed.
- A local `MACPILOT_NOTARY_PROFILE` is optional and must be verified before use. Do not assume a profile named `MacPilot` exists merely because a previous release succeeded.

## Signing identity & designated requirement (invariant)

Every build embeds one **designated requirement** (DR) in the app bundle, and macOS uses it to decide whether an update package is "the same app" as the installed one. It must stay byte-identical across signing identities, machines and agents — a mismatch makes in-app updates impossible to install (this stranded every install below v1.1.355). Nested code (updater, FinderSync appex, helpers, dylib) keeps its own identifier and stays independently signed; only the app bundle's requirement is the shared identity.

- **Single definition:** `Scripts/signing-requirement.sh`. It pins the bundle identifier, Apple's code-signing anchor, and the team OU (`U8U443D7ZL`) — nothing else.
- **Never let codesign derive the requirement**, and never add Developer-ID-only OID clauses or `subject.CN` clauses. Each of those is satisfied by exactly one kind of certificate, so an Apple Development build would stop being "the same app" as a release: updates and privacy grants would stop carrying over in both directions.
- **All four signing paths** (Developer ID, Apple Distribution, Apple Development, ad-hoc) must embed the same bytes. Do not branch the requirement by signing identity.
- **Three gates enforce it:** `Scripts/build-app.sh` (after signing), `Scripts/distribute-app.sh` (after re-packaging), and the `dist` job before `gh release create`. `Tests/MacPilotTests/SigningRequirementTests.swift` is the tripwire test that keeps those gates wired.
- **Never weaken the requirement to make a build pass.** Fix the signing path instead; an already-installed app cannot be talked into accepting a package it does not recognise.
- Formal releases still have to be Developer ID signed and notarized via `Scripts/distribute-app.sh`. Local Apple Development builds share the same identity for TCC/updates but are not distributable (Gatekeeper rejects them).

## Project Summary

The repo-root `SUMMARY.md` is the project's Chinese development summary (features, release flow, pitfalls). Consult it for fuller context beyond this contributor guide.

## Migrated local release facts

- `Scripts/distribute-app.sh` is the reusable local release flow: Developer ID sign, `xcrun notarytool submit --keychain-profile <profile> --wait` when a verified profile exists, otherwise the Apple ID fallback, then `stapler staple`, `stapler validate`, and re-compress the stapled app.
- A profile name such as `MacPilot`, `OctoPilot`, or `octoshrink-notary` is not proof that the profile is usable. Run `xcrun notarytool history --keychain-profile <profile>` in the current session before reuse; do not ask the user to paste passwords into chat.
- The legacy tag workflow needs exactly these six Secrets: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_DEVELOPER_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`. The App-specific password is an Apple ID notarization credential, not a signing certificate.
- GitHub Actions runners cannot read the local Keychain. If importing a `.p12` still produces “No signing certificate ... with a private key was found”, create and unlock a temporary keychain, import the certificate, set the key partition list, and verify with `security find-identity -v -p codesigning`.

## MacPilot release preference

- After MacPilot changes are complete and verified, automatically commit and push `main`, create a new patch Release tag, and verify the GitHub Actions run plus Release assets without waiting for another reminder.
- This applies to **every** pushed change, including docs-only and dead-code-only commits — do not hold a change back on the grounds that it has no user-visible effect.
- `git fetch` and confirm `origin/main` has not moved immediately before tagging; other sessions push here concurrently. If it has, rebase, re-run the gates on the merged tree, and re-derive the version.
- Only GitHub repositories receive GitHub Releases. Never move or overwrite an existing tag; use a new patch version.
- Formal GitHub releases must use the authenticated Developer ID signing and Apple notarization flow above; do not publish an unsigned or unnotarized ZIP as the release asset.
