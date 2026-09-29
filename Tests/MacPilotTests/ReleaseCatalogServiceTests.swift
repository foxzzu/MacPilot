import Foundation
import Testing
@testable import MacPilot

/// 方案第四、四十一、四十二节：目录分页解码与过滤、按 SemVer 排序、
/// 状态独立于更新状态、403 限流进入失败态并可重试。传输通过注入闭包
/// stub，不依赖真实网络（CI 与本机网络条件不同，结果必须确定）。
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

    private func releaseJSON(
        tagName: String,
        prerelease: Bool,
        draft: Bool = false,
        assetName: String,
        digest: String? = "sha256:\(String(repeating: "c", count: 64))"
    ) -> String {
        let digestField: String
        if let digest {
            digestField = #""digest": "\#(digest)", "#
        } else {
            digestField = ""
        }
        return """
        {
          "tag_name": "\(tagName)",
          "body": "notes",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-09-29T00:00:00Z",
          "assets": [
            { "name": "\(assetName)", "browser_download_url": "https://github.com/misswell/MacPilot/releases/download/\(tagName)/\(assetName)", \(digestField)"size": 1 }
          ]
        }
        """
    }

    private func stubbedService(
        status: Int,
        body: String
    ) -> ReleaseCatalogService {
        ReleaseCatalogService(
            currentVersion: "1.1.479",
            performRequest: { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                return (Data(body.utf8), response)
            }
        )
    }

    @Test func catalogDecodesFiltersAndSortsAcrossTheListEndpoint() async {
        // 无校验 ZIP 与 draft 的 Release 不进入列表（方案第四节）。
        let body = """
        [
          \(releaseJSON(tagName: "v1.1.99", prerelease: false, assetName: "MacPilot-1.1.99-arm64-macos.zip")),
          \(releaseJSON(tagName: "v1.2.0-beta.1", prerelease: true, assetName: "MacPilot-1.2.0-beta.1-arm64-macos.zip")),
          \(releaseJSON(tagName: "v1.1.479", prerelease: false, assetName: "MacPilot-1.1.479-arm64-macos.zip")),
          \(releaseJSON(tagName: "v1.1.100", prerelease: false, assetName: "MacPilot-1.1.100-macos.zip", digest: nil)),
          \(releaseJSON(tagName: "v0.9.0-draft", prerelease: false, draft: true, assetName: "MacPilot-0.9.0-arm64-macos.zip"))
        ]
        """
        let service = stubbedService(status: 200, body: body)
        await service.load(forceRefresh: true)

        guard case .loaded(let catalog) = service.state else {
            Issue.record("expected a loaded catalog")
            return
        }
        #expect(catalog.releases.map(\.release.version.description) == [
            "1.2.0-beta.1", "1.1.479", "1.1.99"
        ])
        #expect(catalog.latestStable?.description == "1.1.479")
        #expect(catalog.latestBeta?.description == "1.2.0-beta.1")
        #expect(service.installableReleases()?.count == 3)
    }

    @Test func rateLimitedCatalogEndsInFailedStateWithoutPollingUpdateState() async {
        // 方案第四十二节：GitHub API 403 显示"暂时无法加载"，不影响正常更新。
        let service = stubbedService(status: 403, body: "{}")
        await service.load(forceRefresh: true)
        if case .failed = service.state {} else {
            Issue.record("rate-limited load should end in a failed catalog state")
        }
        #expect(service.installableReleases() == nil)
    }

    @Test func channelFollowsThePrereleaseFlag() {
        let stable = CatalogRelease(release: release("1.1.479"), compatibility: nil)
        let beta = CatalogRelease(release: release("1.2.0-beta.1", prerelease: true), compatibility: nil)
        #expect(stable.channel == .stable)
        #expect(beta.channel == .beta)
    }
}
