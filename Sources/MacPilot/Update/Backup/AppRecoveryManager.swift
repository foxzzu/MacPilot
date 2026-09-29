import Foundation

/// Keeps a local, verified copy of the currently installed app next to the
/// configuration snapshots.
///
/// This is what separates a version manager from a plain updater: after a
/// downgrade to a release that has no Version Manager (and maybe no network),
/// the user must still be able to come back without hunting GitHub for an old
/// ZIP. The ZIP is produced from the exact bundle that is about to be
/// replaced, hashed into the snapshot manifest, and only cleaned up once the
/// user confirms the downgrade test is over.
struct AppRecoveryManager {
    let rootDirectory: URL
    let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    var recoveryDirectory: URL {
        rootDirectory.appendingPathComponent("recovery", isDirectory: true)
    }

    func recoveryZIPName(for version: String) -> String {
        "MacPilot-\(version)-recovery.zip"
    }

    /// Creates (or reuses) the recovery ZIP for the app at `appURL`. The app
    /// must still be the pre-switch bundle when this runs.
    func createRecoveryZIP(
        appURL: URL,
        version: String
    ) throws -> AppRecoveryInfo {
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let name = recoveryZIPName(for: version)
        let destination = recoveryDirectory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: destination.path) {
            try Self.runArchive(source: appURL, destination: destination)
        }
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let digest = try UpdatePackageValidator.sha256(of: destination)
        pruneOtherArchives(keeping: name)
        return AppRecoveryInfo(fileName: name, size: size, sha256: digest, sourceAppVersion: version)
    }

    func recoveryURL(for info: AppRecoveryInfo) -> URL {
        recoveryDirectory.appendingPathComponent(info.fileName)
    }

    /// The stored ZIP only counts as a recovery point while it still matches
    /// the recorded digest.
    func validatedRecoveryURL(for info: AppRecoveryInfo) throws -> URL {
        let url = recoveryURL(for: info)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SnapshotBackupError.configurationFileMissing(info.fileName)
        }
        let digest = try UpdatePackageValidator.sha256(of: url)
        guard digest == info.sha256 else {
            throw SnapshotManifestError.integrityVerificationFailed(info.fileName)
        }
        return url
    }

    func removeRecoveryZIP(for info: AppRecoveryInfo?) {
        guard let info else { return }
        try? fileManager.removeItem(at: recoveryURL(for: info))
    }

    /// Only the newest recovery archive is worth its disk space; older ones
    /// belong to snapshots that no longer have a matching app anyway.
    private func pruneOtherArchives(keeping name: String) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: recoveryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasSuffix("-recovery.zip") && url.lastPathComponent != name {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func runArchive(source: URL, destination: URL) throws {
        fileManagerRemove(destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SnapshotBackupError.configurationFileMissing(source.path)
        }
    }

    private static func fileManagerRemove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
