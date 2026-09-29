import Foundation
import Testing
@testable import MacPilot

/// 方案第四、四十一、四十二节：目录分页解码与过滤、按 SemVer 排序、
/// 状态独立于更新状态、403 限流进入失败态并可重试。传输通过注入闭包
/// stub，不依赖真实网络（CI 与本机网络条件不同，结果必须确定）。
/// 增量加载契约：首页解码后立即上架（首屏不等后续分页与兼容性清单），
/// 清单按批并发补拉并原地刷新条目。
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

    private func compatibilityJSON() -> String {
        """
        {
          "appVersion": "1.1.99",
          "configSchemaVersion": 26,
          "minimumReadableConfigSchema": 20,
          "versionManagerProtocolVersion": 1,
          "rightClickStoreSchemaVersion": 2
        }
        """
    }

    /// 路由式 stub：releases 分页按 URL 页码返回，兼容性清单按资产 URL 返回。
    /// `onRequest` 在每次请求被服务的瞬间执行，用来断言中间状态。
    private func routedService(
        pages: [Int: (body: String, linkHeader: String?)],
        compatibilityAssets: [String: String] = [:],
        onRequest: (@Sendable (URLRequest) async -> Void)? = nil
    ) -> ReleaseCatalogService {
        ReleaseCatalogService(
            currentVersion: "1.1.479",
            performRequest: { request in
                await onRequest?(request)
                let url = request.url!
                if url.path.hasSuffix("/releases"),
                   let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                       .queryItems?.first(where: { $0.name == "page" })?.value,
                   let pageNumber = Int(page),
                   let entry = pages[pageNumber] {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Link": entry.linkHeader ?? ""]
                    )!
                    return (Data(entry.body.utf8), response)
                }
                if let manifest = compatibilityAssets[url.lastPathComponent] {
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(manifest.utf8), response)
                }
                let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
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
        let service = routedService(pages: [1: (body, nil)])
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

    @Test func firstPagePublishesBeforeLaterPagesLoad() async {
        // 上百个版本时首屏不能等所有分页：请求第 2 页的瞬间，第 1 页必须
        // 已经处于 .loaded 状态。
        let page1 = """
        [
          \(releaseJSON(tagName: "v1.2.0-beta.1", prerelease: true, assetName: "MacPilot-1.2.0-beta.1-arm64-macos.zip")),
          \(releaseJSON(tagName: "v1.1.479", prerelease: false, assetName: "MacPilot-1.1.479-arm64-macos.zip"))
        ]
        """
        let page2 = """
        [
          \(releaseJSON(tagName: "v1.1.99", prerelease: false, assetName: "MacPilot-1.1.99-arm64-macos.zip"))
        ]
        """
        final class StateProbe: @unchecked Sendable {
            var sawLoadedOnSecondPageRequest = false
        }
        final class LateServiceBox: @unchecked Sendable {
            weak var service: ReleaseCatalogService?
        }
        let probe = StateProbe()
        let box = LateServiceBox()
        let service = routedService(
            pages: [
                1: (page1, "<https://api.github.com/releases?page=2>; rel=\"next\""),
                2: (page2, nil)
            ],
            onRequest: { request in
                guard let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "page" })?.value, page == "2" else { return }
                let snapshot = await MainActor.run {
                    if case .loaded(let catalog) = box.service?.state {
                        return catalog.releases.map(\.release.version.description)
                    }
                    return [String]()
                }
                if snapshot == ["1.2.0-beta.1", "1.1.479"] {
                    probe.sawLoadedOnSecondPageRequest = true
                }
            }
        )
        box.service = service
        await service.load(forceRefresh: true)

        guard case .loaded(let catalog) = service.state else {
            Issue.record("expected a loaded catalog")
            return
        }
        #expect(catalog.releases.map(\.release.version.description) == [
            "1.2.0-beta.1", "1.1.479", "1.1.99"
        ])
        #expect(probe.sawLoadedOnSecondPageRequest)
    }

    @Test func compatibilityManifestsAttachThroughTheSameTransport() async {
        // 清单与列表共用注入传输，按资产名路由；清单缺失的版本保持"未知"。
        let body = """
        [
          \(releaseJSON(tagName: "v1.1.99", prerelease: false, assetName: "MacPilot-1.1.99-arm64-macos.zip")),
          \(releaseJSON(tagName: "v1.1.479", prerelease: false, assetName: "MacPilot-1.1.479-arm64-macos.zip"))
        ]
        """
        let bodyWithManifest = body.replacingOccurrences(
            of: "\"assets\": [",
            with: "\"assets\": [ { \"name\": \"MacPilot-1.1.99-compatibility.json\", \"browser_download_url\": \"https://github.com/misswell/MacPilot/releases/download/v1.1.99/MacPilot-1.1.99-compatibility.json\", \"size\": 1 },"
        )
        let service = routedService(
            pages: [1: (bodyWithManifest, nil)],
            compatibilityAssets: ["MacPilot-1.1.99-compatibility.json": compatibilityJSON()]
        )
        await service.load(forceRefresh: true)

        guard case .loaded(let catalog) = service.state else {
            Issue.record("expected a loaded catalog")
            return
        }
        let patched = catalog.releases.first { $0.release.version.description == "1.1.99" }
        let unknown = catalog.releases.first { $0.release.version.description == "1.1.479" }
        if let compatibility = patched?.compatibility {
            #expect(patched?.compatibilityState == .compatible(compatibility))
        } else {
            Issue.record("expected the 1.1.99 compatibility manifest to be attached")
        }
        #expect(unknown?.compatibility == nil)
        #expect(unknown?.compatibilityState == .unknown)
    }

    @Test func rateLimitedCatalogEndsInFailedStateWithoutPollingUpdateState() async {
        // 方案第四十二节：GitHub API 403 显示"暂时无法加载"，不影响正常更新。
        let service = ReleaseCatalogService(
            currentVersion: "1.1.479",
            performRequest: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: [:])!
                return (Data("{}".utf8), response)
            }
        )
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
