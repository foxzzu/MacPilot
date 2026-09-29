import Foundation
import Testing
@testable import MacPilot

/// 方案第十六、三十六节：compatibility.json 三档兼容性策略。
struct VersionCompatibilityTests {
    private func manifest(
        minimum: Int = 20,
        versionManager: Int = 1
    ) -> ReleaseCompatibility {
        ReleaseCompatibility(
            appVersion: "1.1.480-beta.1",
            configSchemaVersion: 26,
            minimumReadableConfigSchema: minimum,
            versionManagerProtocolVersion: versionManager,
            rightClickStoreSchemaVersion: 2
        )
    }

    @Test func decodesPublishedManifest() throws {
        let json = """
        {
          "appVersion": "1.2.0",
          "configSchemaVersion": 26,
          "minimumReadableConfigSchema": 20,
          "versionManagerProtocolVersion": 1,
          "rightClickStoreSchemaVersion": 2
        }
        """
        let decoded = try ReleaseCompatibility.decode(Data(json.utf8))
        #expect(decoded.configSchemaVersion == 26)
        #expect(decoded.minimumReadableConfigSchema == 20)
        #expect(decoded.supportsVersionManager)
    }

    @Test func compatibleWhenCurrentSchemaIsReadable() {
        #expect(manifest(minimum: 20).readableByCurrentConfig(currentSchema: 26) == true)
        #expect(manifest(minimum: 26).readableByCurrentConfig(currentSchema: 26) == true)
    }

    @Test func knownIncompatibleWhenTargetCannotReadCurrentSchema() {
        #expect(manifest(minimum: 27).readableByCurrentConfig(currentSchema: 26) == false)
    }

    @Test func compatibilityStatesCoverAllThreeTiers() throws {
        let compatible = CatalogRelease(release: makeRelease("1.1.480"), compatibility: manifest(minimum: 20))
        #expect(compatible.compatibilityState == .compatible(manifest(minimum: 20)))

        let unknown = CatalogRelease(release: makeRelease("1.1.478"), compatibility: nil)
        #expect(unknown.compatibilityState == .unknown)
        #expect(!unknown.compatibilityState.isKnownIncompatible)
        #expect(!unknown.compatibilityState.supportsConfigurationRestore)

        let incompatible = CatalogRelease(release: makeRelease("1.1.100"), compatibility: manifest(minimum: 27))
        #expect(incompatible.compatibilityState.isKnownIncompatible)
        // Even an incompatible release still has a manifest; restore support
        // depends on the version manager protocol version only.
        #expect(incompatible.compatibilityState.supportsConfigurationRestore)
    }

    @Test func versionManagerSupportRequiresTheProtocolVersion() {
        #expect(!manifest(versionManager: 0).supportsVersionManager)
        #expect(manifest(versionManager: 1).supportsVersionManager)
    }

    @Test func assetNameFollowsTheReleaseVersion() throws {
        let version = try #require(SoftwareVersion("1.1.480-beta.1"))
        #expect(VersionCompatibilityService.assetName(for: version) == "MacPilot-1.1.480-beta.1-compatibility.json")
    }

    @Test func configurationSchemaMatchesTheInfoPlistContract() {
        // The build embeds the same numbers the manifest publishes; if they
        // drift, release tooling would describe the wrong schema.
        #expect(ConfigurationSchema.currentVersion == 26)
        #expect(ConfigurationSchema.minimumReadableVersion == 20)
        #expect(ConfigurationSchema.versionManagerProtocolVersion == 1)
        #expect(ConfigurationSchema.rightClickStoreSchemaVersion == 2)
    }

    @Test func currentSystemCheckAcceptsOlderAndRejectsNewerMinimums() {
        #expect(UpdatePackageValidator.currentSystemSatisfies("10.13"))
        let current = ProcessInfo.processInfo.operatingSystemVersion
        #expect(UpdatePackageValidator.currentSystemSatisfies("\(current.majorVersion).\(current.minorVersion)"))
        #expect(!UpdatePackageValidator.currentSystemSatisfies("\(current.majorVersion + 10).0"))
    }
}

private func makeRelease(_ version: String, prerelease: Bool = false) -> SoftwareRelease {
    SoftwareRelease(
        version: SoftwareVersion(version)!,
        releaseNotes: "",
        archiveURL: URL(string: "https://github.com/misswell/MacPilot/releases/download/v\(version)/MacPilot-\(version)-arm64-macos.zip")!,
        sha256: String(repeating: "b", count: 64),
        isPrerelease: prerelease
    )
}
