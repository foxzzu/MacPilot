import Foundation
import Testing
@testable import MacPilot

struct UpdateChannelTests {
    @Test func bundleMetadataPreservesTheFullBetaVersionAndChannel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Channel-\(UUID().uuidString).bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.misswell.macpilot", "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.7.0", "CFBundleVersion": "42",
            "MacPilotVersion": "1.7.0-beta.2", "MacPilotUpdateChannel": "beta"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))
        #expect(AppVersionInfo.current(bundle: bundle).version == "1.7.0-beta.2")
        #expect(AppChannel.installed(bundle: bundle) == .beta)
    }

    @Test func semverOrdersPrereleasesAndIgnoresBuildMetadata() throws {
        let values = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.1.0-beta.1"]
        let versions = try values.map { try #require(SoftwareVersion($0)) }
        for (left, right) in zip(versions, versions.dropFirst()) { #expect(left < right) }
        #expect(SoftwareVersion("1.0.0+build.01") == SoftwareVersion("1.0.0+other"))
        #expect(Set([SoftwareVersion("1.0.0+one"), SoftwareVersion("1.0.0+two")]).count == 1)
        for value in ["1.0.0-beta.01", "01.0.0", "1.0.0-", "1.0.0+", "1.0.0-β", "1.0.0.1"] {
            #expect(SoftwareVersion(value) == nil)
        }
        #expect(SoftwareVersion("1.0.0-beta.999999999999999999999999")! > SoftwareVersion("1.0.0-beta.99999999999999999999999")!)
    }

    @Test func oldConfigurationsMigrateToStableAndPersistTheChannel() throws {
        var config = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: Data("{}".utf8))
        #expect(config.updateChannel == .stable)
        config.updateChannel = .beta
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: data).updateChannel == .beta)
        let unknown = try JSONDecoder().decode(MacPilotModel.StoredConfiguration.self, from: Data(#"{"updateChannel":"future"}"#.utf8))
        #expect(unknown.updateChannel == .stable)
    }

    private func release(_ version: String, prerelease: Bool, draft: Bool = false) -> [String: Any] {
        ["tag_name": "v\(version)", "body": "", "draft": draft, "prerelease": prerelease,
         "published_at": "2026-09-28T00:00:00Z",
         "assets": [["name": "MacPilot-\(version)-macos.zip",
                     "browser_download_url": "https://example.com/MacPilot-\(version)-macos.zip",
                     "digest": "sha256:" + String(repeating: "a", count: 64)]]]
    }

    @Test func betaSelectionUsesSemverAndRejectsDraftsAndStableReleases() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            release("1.7.0-beta.2", prerelease: true),
            release("1.7.0-beta.10", prerelease: true),
            release("2.0.0", prerelease: false),
            release("3.0.0-beta.1", prerelease: true, draft: true),
            release("4.0.0-rc.1", prerelease: true)
        ])
        let beta = try #require(try ReleaseFetcher.selectBeta(data))
        #expect(beta.version.description == "1.7.0-beta.10")
        #expect(beta.isPrerelease)
        #expect(beta.publishedAt != nil)
        #expect(!beta.isNewer(than: "1.7.0"))
        #expect(!beta.isNewer(than: "1.8.0-beta.1"))
        #expect(try ReleaseFetcher.selectBeta(Data("[]".utf8)) == nil)
    }

    @Test func stableRejectsPrereleasesAndNeverOffersADowngrade() throws {
        let beta = try JSONSerialization.data(withJSONObject: release("1.7.0-beta.3", prerelease: true))
        #expect(throws: SoftwareUpdateError.invalidRelease) { try SoftwareRelease.decodeGitHubResponse(beta) }
        let stable = try SoftwareRelease.decodeGitHubResponse(JSONSerialization.data(withJSONObject: release("1.6.0", prerelease: false)))
        #expect(!stable.isNewer(than: "1.7.0-beta.5"))
        #expect(!stable.isNewer(than: "1.6.0"))
    }

    @MainActor @Test func switchingChannelsClearsAnEarlierCheck() {
        let updater = SoftwareUpdater(currentVersion: "1.6.0")
        #expect(updater.channel == .stable)
        updater.setChannel(.beta)
        #expect(updater.channel == .beta)
        #expect(updater.state == .idle)
        updater.setChannel(.stable)
        #expect(updater.channel == .stable)
    }

    @MainActor @Test func checksBothEndpointsAndFindsBetaOnLaterPages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChannelURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let updater = SoftwareUpdater(currentVersion: "1.6.0", session: session)
        await updater.checkForUpdates()
        #expect(updater.state == .upToDate)
        updater.setChannel(.beta)
        await updater.checkForUpdates()
        let beta = try #require(updater.state.availableRelease)
        #expect(beta.version.description == "1.7.0-beta.10")
        updater.setChannel(.stable)
        #expect(updater.state.availableRelease == nil)
        await updater.checkForUpdates()
        #expect(updater.state == .upToDate)
    }
}

private final class ChannelURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let stable = url.path.hasSuffix("/latest")
        let firstPage = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "page" })?.value == "1"
        let version = stable ? "1.6.0" : (firstPage ? "1.7.0-beta.2" : "1.7.0-beta.10")
        let release: [String: Any] = [
            "tag_name": "v\(version)", "body": NSNull(), "draft": false, "prerelease": !stable,
            "assets": [["name": "MacPilot-\(version)-macos.zip",
                        "browser_download_url": "https://example.com/MacPilot-\(version)-macos.zip",
                        "digest": "sha256:" + String(repeating: "b", count: 64)]]
        ]
        let headers = !stable && firstPage ? ["Link": "<https://api.github.com/releases?page=2>; rel=\"next\""] : [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        do {
            let data = try JSONSerialization.data(withJSONObject: stable ? release : [release])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
