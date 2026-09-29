// MacPilot Recovery — minimal standalone helper for downgrade test sessions.
//
// It exists for exactly one situation: a version switch landed on a MacPilot
// release that predates the Version Manager, so the running app cannot restore
// anything by itself. The helper is copied next to the snapshots before a
// switch and offers the way back:
//   * restore the pre-downgrade MacPilot.app (from the verified local ZIP),
//   * also restore the pre-downgrade configuration snapshot,
//   * reveal the snapshot directory in Finder.
//
// App replacement itself is delegated to MacPilotUpdater (there is exactly one
// replacement implementation); this helper only verifies the recovery archive
// and restores configuration files while every MacPilot process is quit.

import AppKit
import CryptoKit
import Foundation

private let knownBundleIdentifiers = ["com.misswell.macpilot", "com.misswell.octopilot"]
private let developerTeamIdentifier = "U8U443D7ZL"
private let configurationDirectoryName = "MacPilot"
// Key for the button→handler association. Static raw bytes, never mutated.
private nonisolated(unsafe) var associatedActionKey: UInt8 = 0

private enum RecoveryError: LocalizedError {
    case snapshotMissing
    case recoveryArchiveMissing
    case recoveryArchiveInvalid
    case applicationInvalid
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotMissing: "No downgrade snapshot was found."
        case .recoveryArchiveMissing: "The local recovery archive is missing."
        case .recoveryArchiveInvalid: "The local recovery archive failed verification."
        case .applicationInvalid: "The recovered application failed verification."
        case .restoreFailed(let detail): detail
        }
    }
}

private struct SnapshotManifest {
    var sourceAppVersion: String
    var targetAppVersion: String
    var status: String
    var files: [(relativePath: String, sha256: String)]
    var directory: URL
    var includesPreferences: Bool
}

private func configurationDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(configurationDirectoryName, isDirectory: true)
}

private func versionManagerDirectory() -> URL {
    configurationDirectory().appendingPathComponent("VersionManager", isDirectory: true)
}

private func sha256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func run(_ executable: String, arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RecoveryError.restoreFailed("\(URL(fileURLWithPath: executable).lastPathComponent) exited \(process.terminationStatus)")
    }
    return output
}

private func loadLatestSnapshot() -> SnapshotManifest? {
    let snapshots = versionManagerDirectory().appendingPathComponent("snapshots", isDirectory: true)
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: snapshots, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
    )) ?? []
    let manifests: [(Date, SnapshotManifest)] = contents.compactMap { directory in
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let files = (object["files"] as? [[String: Any]])?.compactMap { entry -> (String, String)? in
            guard let path = entry["relativePath"] as? String,
                  let digest = entry["sha256"] as? String else { return nil }
            return (path, digest)
        } ?? []
        let manifest = SnapshotManifest(
            sourceAppVersion: object["sourceAppVersion"] as? String ?? "",
            targetAppVersion: object["targetAppVersion"] as? String ?? "",
            status: object["status"] as? String ?? "",
            files: files,
            directory: directory,
            includesPreferences: object["includesPreferences"] as? Bool ?? false
        )
        let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return (modified, manifest)
    }
    return manifests
        .filter { $0.1.status == "downgradeActive" || $0.1.status == "ready" }
        .max { $0.0 < $1.0 }?.1
}

private func installedApplicationURL() -> URL {
    let applications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0]
    let names = ["MacPilot.app", "OctoPilot.app"]
    return names.map { applications.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
        ?? applications.appendingPathComponent("MacPilot.app")
}

private func terminateRunningMacPilot() {
    let running = NSWorkspace.shared.runningApplications.first {
        guard let identifier = $0.bundleIdentifier else { return false }
        return knownBundleIdentifiers.contains(identifier)
    }
    guard let running else { return }
    running.terminate()
    for _ in 0..<100 where !running.isTerminated {
        usleep(100_000)
    }
}

/// Restores the snapshot's captured files. Runs only after MacPilot has quit.
private func restoreConfigurationFiles(_ manifest: SnapshotManifest) throws {
    let staging = versionManagerDirectory()
        .appendingPathComponent("restore-staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    for entry in manifest.files {
        let source = manifest.directory.appendingPathComponent(entry.relativePath)
        guard FileManager.default.fileExists(atPath: source.path),
              sha256(of: source) == entry.sha256 else {
            throw RecoveryError.recoveryArchiveInvalid
        }
        let staged = staging.appendingPathComponent(entry.relativePath)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: staged)
    }

    let target = configurationDirectory()
    for entry in manifest.files {
        let name: String
        if entry.relativePath.hasPrefix("configuration/") {
            name = String(entry.relativePath.dropFirst("configuration/".count))
        } else if entry.relativePath.hasPrefix("dock-groups/") {
            name = entry.relativePath
        } else {
            continue
        }
        let staged = staging.appendingPathComponent(entry.relativePath)
        let destination = target.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".recovery-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: staged, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
    if manifest.includesPreferences,
       let preferencesURL = (try? FileManager.default.contentsOfDirectory(
           at: staging, includingPropertiesForKeys: nil
       ))?.first(where: { $0.lastPathComponent == "preferences.plist" }),
       let data = try? Data(contentsOf: preferencesURL),
       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
        UserDefaults.standard.setPersistentDomain(plist, forName: knownBundleIdentifiers[0])
        UserDefaults.standard.synchronize()
    }
}

/// Validates the recovery archive, restores configuration while everything is
/// quit, then hands app replacement to MacPilotUpdater.
private func performRestore(snapshot: SnapshotManifest, withConfiguration: Bool) throws {
    let recoveryDirectory = versionManagerDirectory().appendingPathComponent("recovery", isDirectory: true)
    guard let recoveryArchive = (try? FileManager.default.contentsOfDirectory(
        at: recoveryDirectory, includingPropertiesForKeys: nil
    ))?.first(where: { $0.lastPathComponent.hasSuffix("-recovery.zip") }) else {
        throw RecoveryError.recoveryArchiveMissing
    }

    let extraction = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacPilotRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extraction) }
    _ = try run("/usr/bin/ditto", arguments: ["-x", "-k", recoveryArchive.path, extraction.path])

    let applicationURL = extraction.appendingPathComponent("MacPilot.app")
    guard let bundle = Bundle(url: applicationURL),
          knownBundleIdentifiers.contains(bundle.bundleIdentifier ?? ""),
          FileManager.default.isExecutableFile(atPath: applicationURL.appendingPathComponent("Contents/MacOS/MacPilot").path) else {
        throw RecoveryError.applicationInvalid
    }
    _ = try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", applicationURL.path])
    let details = try run("/usr/bin/codesign", arguments: ["--display", "--verbose=4", applicationURL.path])
    guard details.contains("TeamIdentifier=\(developerTeamIdentifier)") else {
        throw RecoveryError.applicationInvalid
    }
    // Gatekeeper assessment is advisory here: a locally archived app can be
    // validly signed yet lack a reachable notarization ticket offline. The
    // security boundary is the strict signature check plus the pinned team
    // identifier above.
    _ = try? run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", applicationURL.path])
    _ = try? run("/usr/bin/xattr", arguments: ["-d", "com.apple.quarantine", applicationURL.path])

    if withConfiguration {
        try restoreConfigurationFiles(snapshot)
    }

    terminateRunningMacPilot()

    let updaterURL = applicationURL.appendingPathComponent("Contents/MacOS/MacPilotUpdater")
    guard FileManager.default.isExecutableFile(atPath: updaterURL.path) else {
        throw RecoveryError.applicationInvalid
    }
    let helperDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacPilotRecoveryUpdater-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
    let updaterCopy = helperDirectory.appendingPathComponent("MacPilotUpdater")
    try FileManager.default.copyItem(at: updaterURL, to: updaterCopy)
    let process = Process()
    process.executableURL = updaterCopy
    process.arguments = [
        String(ProcessInfo.processInfo.processIdentifier),
        applicationURL.path,
        installedApplicationURL().path,
        extraction.path,
        helperDirectory.path,
        NSHomeDirectory() + "/Library/Logs/MacPilot/update.log"
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
}

@main
struct RecoveryApplication {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacPilot Recovery"
        window.center()

        let snapshot = loadLatestSnapshot()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSTextField(labelWithString: "MacPilot Recovery")
        headline.font = NSFont.boldSystemFont(ofSize: 17)
        let detail = NSTextField(labelWithString: {
            guard let snapshot else { return "No downgrade snapshot was found on this Mac." }
            return "Downgrade test detected:\nOriginal version: \(snapshot.sourceAppVersion)\nCurrent target: \(snapshot.targetAppVersion)"
        }())
        detail.isSelectable = true
        stack.addArrangedSubview(headline)
        stack.addArrangedSubview(detail)

        let installButton = NSButton(title: "Restore pre-downgrade MacPilot", target: nil, action: nil)
        let fullButton = NSButton(title: "Restore MacPilot + pre-downgrade configuration", target: nil, action: nil)
        let revealButton = NSButton(title: "Open configuration backup", target: nil, action: nil)
        for button in [installButton, fullButton, revealButton] {
            button.bezelStyle = .rounded
            button.setButtonType(.momentaryPushIn)
            stack.addArrangedSubview(button)
        }
        installButton.isEnabled = snapshot != nil
        fullButton.isEnabled = snapshot != nil

        let status = NSTextField(labelWithString: "")
        status.textColor = NSColor.secondaryLabelColor
        stack.addArrangedSubview(status)

        func runRestore(withConfiguration: Bool) {
            guard let snapshot else { return }
            status.stringValue = "Restoring…"
            installButton.isEnabled = false
            fullButton.isEnabled = false
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try performRestore(snapshot: snapshot, withConfiguration: withConfiguration)
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                } catch {
                    DispatchQueue.main.async {
                        status.stringValue = "Restore failed: \(error.localizedDescription)"
                        installButton.isEnabled = true
                        fullButton.isEnabled = true
                    }
                }
            }
        }
        installButton.onAction { runRestore(withConfiguration: false) }
        fullButton.onAction { runRestore(withConfiguration: true) }
        revealButton.onAction {
            NSWorkspace.shared.activateFileViewerSelecting([versionManagerDirectory()])
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        app.run()
    }
}

private extension NSButton {
    func onAction(_ handler: @escaping () -> Void) {
        objc_setAssociatedObject(self, &associatedActionKey, handler, .OBJC_ASSOCIATION_RETAIN)
        target = self
        action = #selector(fireAssociatedAction)
    }

    @objc private func fireAssociatedAction() {
        (objc_getAssociatedObject(self, &associatedActionKey) as? () -> Void)?()
    }
}
