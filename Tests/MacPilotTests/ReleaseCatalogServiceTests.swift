import Foundation
import Testing
@testable import MacPilot

/// 方案第四十二节：目录缓存 TTL 与排序；第四十一节：目录状态独立于更新状态。
@MainActor
struct ReleaseCatalogServiceTests {
    private func release(_ version: String, prerelease: Bool = false) -> SoftwareRelease {
        SoftwareRelease(
            version: SoftwareVersion(version)!,
            releaseNotes: "notes",
            archiveURL: URL(string: "https://github.com/misswell/MacPilot/releases/download/v\(version)/MacPilot-\(version)-arm64-macos.zip")!,
            sha256: String(repeating: "c", count: 64),
            isPrerelease: prerelease
        )
    }

    @Test func catalogSortsBySemVerNotListOrder() {
        let catalog = VersionCatalog(
            releases: [
                CatalogRelease(release: release("1.1.99"), compatibility: nil),
                CatalogRelease(release: release("1.2.0-beta.1", prerelease: true), compatibility: nil),
                CatalogRelease(release: release("1.1.479"), compatibility: nil),
                CatalogRelease(release: release("1.1.478"), compatibility: nil)
            ],
            fetchedAt: Date()
        )
        #expect(catalog.releases.map(\.release.version.description) == [
            "1.2.0-beta.1", "1.1.479", "1.1.99", "1.1.478"
        ])
        #expect(catalog.latestStable?.description == "1.1.479")
        #expect(catalog.latestBeta?.description == "1.2.0-beta.1")
    }

    @Test func channelFollowsThePrereleaseFlag() {
        let stable = CatalogRelease(release: release("1.1.479"), compatibility: nil)
        let beta = CatalogRelease(release: release("1.2.0-beta.1", prerelease: true), compatibility: nil)
        #expect(stable.channel == .stable)
        #expect(beta.channel == .beta)
    }

    @Test func offlineLoadEndsInFailedStateWithoutPollingUpdateState() async {
        // 方案第四十一节：目录加载失败只反映在 ReleaseCatalogState 上，
        // 不触碰 SoftwareUpdateState（菜单栏不应出现"正在检查更新"）。
        let service = ReleaseCatalogService(
            currentVersion: "1.1.479",
            now: { Date() }
        )
        await service.load(forceRefresh: true)
        if case .failed = service.state {} else {
            Issue.record("Offline load should end in a failed catalog state")
        }
        #expect(service.installableReleases() == nil)
    }
}
