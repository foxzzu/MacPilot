import Foundation

/// Backs up and restores the app's whole UserDefaults persistent domain.
///
/// A hand-maintained key whitelist rots: every new `UserDefaults` key would
/// need to be remembered here or a downgrade would silently drop its value.
/// The policy is therefore the opposite — the entire domain is captured, and
/// only an explicit denylist of runtime/caching keys is excluded from restore.
enum PreferenceSnapshotManager {
    /// Runtime or transient state that must never be replayed by a restore:
    /// mirror selection for update downloads, one-shot migration progress and
    /// similar markers that describe a specific launch, not a user preference.
    static let denylistedKeys: Set<String> = [
        "updateDownloadMirrorHost",
        "rightClickStoreMigrationPendingV2"
    ]

    static func snapshotDomain(
        bundleIdentifier: String = AppIdentity.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) -> [String: Any] {
        defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    }

    static func writeSnapshot(_ domain: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: domain,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func readSnapshot(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let domain = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return domain
    }

    /// Restores the domain minus denylisted keys. Only safe while the feature
    /// runtimes have not read their defaults yet — the startup finalizer runs
    /// this before the app model initializes.
    static func restore(
        from url: URL,
        bundleIdentifier: String = AppIdentity.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) throws {
        let domain = try readSnapshot(from: url)
        defaults.setPersistentDomain(applyingDenylist(domain), forName: bundleIdentifier)
        defaults.synchronize()
    }

    static func applyingDenylist(_ domain: [String: Any]) -> [String: Any] {
        domain.filter { !denylistedKeys.contains($0.key) }
    }
}
