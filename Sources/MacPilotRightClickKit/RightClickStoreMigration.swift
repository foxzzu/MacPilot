import Foundation
import SQLite3

/// Only the main app uses SwiftData. Keep its store in Application Support;
/// the extension receives menu configuration over authenticated IPC instead.
enum RightClickStoreMigration {
    static let pendingKey = "rightClickStoreMigrationPendingV2"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/RightClick", isDirectory: true)
    }
    static var destination: URL { directory.appendingPathComponent("RClickDatabase-v2.sqlite") }
    /// The old App Group is protected app data on macOS. It is intentionally
    /// only included for an explicit recovery action from Settings.
    static var protectedLegacySource: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Group Containers/group.com.misswell.macpilot.rightclick/RClickDatabase.sqlite")
    }
    static var applicationSupportLegacySource: URL {
        directory.appendingPathComponent("RClickDatabase.sqlite")
    }
    static var legacySources: [URL] {
        [protectedLegacySource, applicationSupportLegacySource]
    }

    /// The normal startup path only probes the unprotected Application Support
    /// fallback. Access to the old App Group is opt-in from Settings because
    /// probing it causes macOS to show the App Data consent dialog on updates.
    static func prepare(
        destination: URL = destination,
        sources: [URL]? = nil,
        defaults: UserDefaults = .standard,
        retry: Bool = false,
        migrate: (URL, URL) throws -> Bool = copyIfPresent
    ) -> Bool {
        if FileManager.default.fileExists(atPath: destination.path) {
            defaults.set(false, forKey: pendingKey)
            return true
        }
        guard retry || !defaults.bool(forKey: pendingKey) else { return false }
        let isAutomaticStartup = sources == nil && !retry
        let resolvedSources = sources ?? (retry ? legacySources : [applicationSupportLegacySource])
        defaults.set(true, forKey: pendingKey)
        // Persist before entering TCC, including when the process is killed
        // while the consent dialog is open.
        defaults.synchronize()
        do {
            for (index, source) in resolvedSources.enumerated() {
                let sourceLabel = source == protectedLegacySource ? "protected-legacy" : "application-support-legacy"
                PermissionDiagnostics.record("database.migration.begin source=\(sourceLabel) index=\(index)")
                if try migrate(source, destination) {
                    PermissionDiagnostics.record("database.migration.end copied=true")
                    defaults.set(false, forKey: pendingKey)
                    return true
                }
            }

            // An existing MacPilot installation may still have its right-click
            // store in the old App Group. Do not inspect that protected path
            // during startup; leave the store untouched and let the user opt
            // into recovery from Settings.
            if isAutomaticStartup && hasExistingConfiguration {
                PermissionDiagnostics.record("database.migration.deferred protectedLegacyStorePending=true")
                return false
            }

            PermissionDiagnostics.record("database.migration.end legacyStoreAbsent=true")
            defaults.set(false, forKey: pendingKey)
            return true
        } catch {
            let failure = error as NSError
            PermissionDiagnostics.record("database.migration.deferred domain=\(failure.domain) code=\(failure.code)")
            return false
        }
    }

    private static var hasExistingConfiguration: Bool {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configuration = applicationSupport
            .appendingPathComponent("MacPilot", isDirectory: true)
            .appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: configuration.path)
    }

    static func copyIfPresent(from source: URL, to destination: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: source.path)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return false
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // The SQLite backup API includes committed WAL transactions. Never
        // copy just the main sqlite file and silently discard newer settings.
        try SQLiteSnapshot.create(from: source, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return true
    }
}
