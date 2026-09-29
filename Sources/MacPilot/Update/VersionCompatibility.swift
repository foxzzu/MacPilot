import Foundation

/// The configuration schema this build writes. The same number is embedded in
/// Info.plist (`MacPilotConfigSchemaVersion`) so release tooling and the
/// compatibility manifest can reference it without linking the app code.
enum ConfigurationSchema {
    static let currentVersion = 26
    /// The oldest configuration schema this build still decodes.
    static let minimumReadableVersion = 20
    /// Wire contract between the Version Manager, snapshots and the updater.
    static let versionManagerProtocolVersion = 1
    /// `RightClickStoreMigration` v2 database (`RClickDatabase-v2.sqlite`).
    static let rightClickStoreSchemaVersion = 2

    static func configSchemaVersion(bundle: Bundle = .main) -> Int {
        bundle.object(forInfoDictionaryKey: "MacPilotConfigSchemaVersion") as? Int ?? currentVersion
    }

    static func versionManagerProtocolVersion(bundle: Bundle = .main) -> Int {
        bundle.object(forInfoDictionaryKey: "MacPilotVersionManagerProtocolVersion") as? Int
            ?? versionManagerProtocolVersion
    }
}

/// The per-release compatibility manifest (`MacPilot-<version>-compatibility.json`)
/// published alongside every release. Historical releases have none; that is
/// meaningful on its own (compatibility unknown) and must never be guessed.
struct ReleaseCompatibility: Codable, Equatable {
    let appVersion: String
    let configSchemaVersion: Int
    let minimumReadableConfigSchema: Int
    let versionManagerProtocolVersion: Int
    let rightClickStoreSchemaVersion: Int

    /// Whether this release is known to be able to read configurations written
    /// by `currentSchema`. `nil` means unknown: no manifest was published.
    func readableByCurrentConfig(currentSchema: Int = ConfigurationSchema.currentVersion) -> Bool? {
        guard minimumReadableConfigSchema <= currentSchema else { return false }
        return true
    }

    /// Whether this release ships the Version Manager and can therefore also
    /// apply a pending configuration restore when it launches.
    var supportsVersionManager: Bool { versionManagerProtocolVersion >= 1 }

    static func decode(_ data: Data) throws -> ReleaseCompatibility {
        try JSONDecoder().decode(ReleaseCompatibility.self, from: data)
    }
}

/// Three-state compatibility policy for installing an arbitrary historical
/// release. Unknown is the honest answer for anything published before the
/// manifest existed; installs stay allowed either way, and downgrades always
/// snapshot regardless.
enum ConfigurationCompatibility: Equatable {
    case compatible(ReleaseCompatibility)
    case unknown
    case knownIncompatible(ReleaseCompatibility)

    init(release: CatalogRelease, currentSchema: Int = ConfigurationSchema.currentVersion) {
        guard let manifest = release.compatibility else {
            self = .unknown
            return
        }
        if manifest.readableByCurrentConfig(currentSchema: currentSchema) == true {
            self = .compatible(manifest)
        } else {
            self = .knownIncompatible(manifest)
        }
    }

    var isKnownIncompatible: Bool {
        if case .knownIncompatible = self { return true }
        return false
    }

    /// Whether the target release is known to run the Version Manager and can
    /// therefore consume a pending configuration restore. Unknown (no
    /// manifest) means no — never assume.
    var supportsConfigurationRestore: Bool {
        switch self {
        case .compatible(let manifest), .knownIncompatible(let manifest):
            manifest.supportsVersionManager
        case .unknown:
            false
        }
    }
}

enum VersionCompatibilityService {
    static let assetSuffix = "-compatibility.json"

    /// `MacPilot-1.2.0-compatibility.json` — the asset name release tooling
    /// publishes next to the update archives.
    static func assetName(for version: SoftwareVersion) -> String {
        "MacPilot-\(version.description)\(assetSuffix)"
    }

    static func fetch(
        for release: GitHubReleaseResponse,
        currentVersion: String,
        performRequest: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> ReleaseCompatibility? {
        guard let asset = release.assets.first(where: { $0.name == assetName(forVersion: release.tagName) }),
              asset.url.scheme == "https" else {
            return nil
        }
        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 20
        request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await performRequest(request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return try? ReleaseCompatibility.decode(data)
    }

    private static func assetName(forVersion tagName: String) -> String {
        guard let version = SoftwareVersion(tagName) else { return "MacPilot-\(tagName)\(assetSuffix)" }
        return assetName(for: version)
    }
}
