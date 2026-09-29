import Foundation
import Testing
@testable import MacPilot

struct SoftwareUpdateTests {
    @Test func parsesDesignatedRequirementFromCodesignOutput() {
        let output = """
        Executable=/Applications/MacPilot.app/Contents/MacOS/MacPilot
        Identifier=com.misswell.macpilot
        designated => identifier "com.misswell.macpilot" and anchor apple generic
        """

        #expect(
            UpdatePackageValidator.parseDesignatedRequirement(from: output)
                == "identifier \"com.misswell.macpilot\" and anchor apple generic"
        )
        #expect(UpdatePackageValidator.parseDesignatedRequirement(from: "no requirement line") == "")
    }

    @Test func requirementSatisfactionDecidesWhetherPrivacyGrantsSurvive() {
        // The update check must accept a package that satisfies the running
        // app's recorded requirement even when the two requirement strings
        // differ, and must still reject unrelated code.
        let appleBinary = URL(fileURLWithPath: "/bin/echo")

        #expect(UpdatePackageValidator.satisfies("anchor apple generic", at: appleBinary))
        #expect(!UpdatePackageValidator.satisfies(
            "identifier \"com.misswell.macpilot\" and anchor apple generic",
            at: appleBinary
        ))
        #expect(!UpdatePackageValidator.satisfies("", at: appleBinary))
    }

    @Test func comparesSemanticVersionsNumerically() throws {
        let current = try #require(SoftwareVersion("1.9.9"))
        let available = try #require(SoftwareVersion("v1.10.0"))

        #expect(current < available)
        #expect(SoftwareVersion("1.10") == SoftwareVersion("1.10.0"))
        #expect(SoftwareVersion("not-a-version") == nil)
    }

    @Test func decodesReleaseAndSelectsArmArchive() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "name": "MacPilot v1.2.3",
          "body": "Safer updates",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "source.zip",
              "browser_download_url": "https://example.com/source.zip",
              "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
              "name": "MacPilot-1.2.3-macos.zip",
              "browser_download_url": "https://example.com/MacPilot-1.2.3-macos.zip",
              "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            },
            {
              "name": "MacPilot-1.2.3-x86_64-macos.zip",
              "browser_download_url": "https://example.com/MacPilot-1.2.3-x86_64-macos.zip",
              "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
              "name": "MacPilot-1.2.3-arm64-macos.zip",
              "browser_download_url": "https://example.com/MacPilot-1.2.3-arm64-macos.zip",
              "digest": "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
            }
          ]
        }
        """

        let release = try SoftwareRelease.decodeGitHubResponse(
            Data(json.utf8),
            architecture: .arm64
        )

        #expect(release.version == SoftwareVersion("1.2.3"))
        #expect(release.releaseNotes == "Safer updates")
        #expect(release.archiveURL.absoluteString == "https://example.com/MacPilot-1.2.3-arm64-macos.zip")
        #expect(release.sha256 == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
    }

    @Test func decodesReleaseAndSelectsIntelArchive() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "MacPilot-1.2.3-arm64-macos.zip",
              "browser_download_url": "https://example.com/MacPilot-1.2.3-arm64-macos.zip",
              "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
              "name": "MacPilot-1.2.3-x86_64-macos.zip",
              "browser_download_url": "https://example.com/MacPilot-1.2.3-x86_64-macos.zip",
              "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            }
          ]
        }
        """

        let release = try SoftwareRelease.decodeGitHubResponse(
            Data(json.utf8),
            architecture: .x86_64
        )

        #expect(release.archiveURL.lastPathComponent == "MacPilot-1.2.3-x86_64-macos.zip")
        #expect(release.sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    @Test func decodesReleaseAssetsFromGitHubWebPage() throws {
        let html = """
        <a href="/misswell/MacPilot/releases/download/v1.2.3/MacPilot-1.2.3-arm64-macos.zip">
        <span>MacPilot for Apple Silicon</span>
        <span>sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789</span>
        """

        let release = try SoftwareRelease.decodeGitHubAssetsHTML(
            Data(html.utf8),
            tagName: "v1.2.3",
            architecture: .arm64
        )

        #expect(release.version == SoftwareVersion("1.2.3"))
        #expect(release.archiveURL.absoluteString == "https://github.com/misswell/MacPilot/releases/download/v1.2.3/MacPilot-1.2.3-arm64-macos.zip")
        #expect(release.sha256 == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
    }

    @Test func fallsBackToUniversalArchiveWhenArchitectureAssetIsMissing() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "MacPilot-1.2.3-macos.zip",
            "browser_download_url": "https://example.com/MacPilot-1.2.3-macos.zip",
            "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
          }]
        }
        """

        let release = try SoftwareRelease.decodeGitHubResponse(
            Data(json.utf8),
            architecture: .arm64
        )

        #expect(release.archiveURL.lastPathComponent == "MacPilot-1.2.3-macos.zip")
    }

    @Test func acceptsLegacyArchiveNameDuringRenameTransition() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "OctoPilot-1.2.3-macos.zip",
            "browser_download_url": "https://example.com/OctoPilot-1.2.3-macos.zip",
            "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
          }]
        }
        """

        let release = try SoftwareRelease.decodeGitHubResponse(Data(json.utf8))

        #expect(release.archiveURL.lastPathComponent == "OctoPilot-1.2.3-macos.zip")
    }

    @Test func appIdentityKeepsLegacyBundleForMigration() {
        #expect(AppIdentity.bundleIdentifier == "com.misswell.macpilot")
        #expect(AppIdentity.knownBundleIdentifiers.contains("com.misswell.octopilot"))
        #expect(AppIdentity.archiveNames(for: "1.2.3", architecture: .x86_64) == [
            "MacPilot-1.2.3-x86_64-macos.zip",
            "MacPilot-1.2.3-macos.zip",
            "OctoPilot-1.2.3-x86_64-macos.zip",
            "OctoPilot-1.2.3-macos.zip"
        ])
    }

    @Test func githubProjectLinkUsesCanonicalRepository() {
        #expect(AppIdentity.githubURL.absoluteString == "https://github.com/misswell/MacPilot")
        #expect(AppText.value("githubProjectLink", language: .simplifiedChinese, AppIdentity.githubRepository) == "github.com/misswell/MacPilot")
        #expect(AppText.value("githubProjectLink", language: .english, AppIdentity.githubRepository) == "github.com/misswell/MacPilot")
    }

    @Test func reportsAnUpdateOnlyForANewerVersion() throws {
        let release = SoftwareRelease(
            version: try #require(SoftwareVersion("2.0.0")),
            releaseNotes: "",
            archiveURL: try #require(URL(string: "https://example.com/update.zip")),
            sha256: String(repeating: "a", count: 64)
        )

        #expect(release.isNewer(than: "1.9.9"))
        #expect(!release.isNewer(than: "2.0"))
        #expect(!release.isNewer(than: "2.1.0"))
        #expect(!release.isNewer(than: "development"))
    }

    @Test func rejectsAnArchiveWithoutGitHubsDigest() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "MacPilot-1.2.3-macos.zip",
            "browser_download_url": "https://example.com/update.zip",
            "digest": null
          }]
        }
        """

        do {
            _ = try SoftwareRelease.decodeGitHubResponse(Data(json.utf8))
            Issue.record("A release without a SHA-256 digest was accepted")
        } catch let error as SoftwareUpdateError {
            #expect(error == .missingVerifiedArchive)
        }
    }

    @Test func computesArchiveSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("MacPilot".utf8).write(to: url, options: .atomic)

        #expect(try UpdatePackageValidator.sha256(of: url) == "b10258073cf5d4342e110670f209c169f6782b984152416bbdcd61d77a1dbdc7")
    }

    @Test func localizesUpdateActionsAndFailures() {
        #expect(AppText.value("downloadAndInstall", language: .simplifiedChinese) == "下载并安装")
        #expect(AppText.value("downloadAndInstall", language: .english) == "Download and Install")
        #expect(AppText.value("updateErrorLocation", language: .simplifiedChinese).contains("应用程序"))
        #expect(AppText.value("updateErrorLocation", language: .english).contains("Applications"))
    }
}

/// `downloadAndValidate` 的 `isCancelled` 是"已取消"语义，下载链要的是
/// "继续"语义。极性一旦传反，每次下载都会在第一个镜像之前抛
/// CancellationError——v1.1.482 的版本切换正是这样失败的。
@MainActor
struct DownloadAndValidatePolarityTests {
    private func makeRelease(sha256: String) -> SoftwareRelease {
        SoftwareRelease(
            version: SoftwareVersion("1.1.480")!,
            releaseNotes: "",
            archiveURL: URL(
                string: "https://github.com/\(AppIdentity.githubRepository)/releases/download/v1.1.480/MacPilot-1.1.480-arm64-macos.zip"
            )!,
            sha256: sha256
        )
    }

    @Test func defaultSeamIsNotCancelledAndStillAttemptsTheFirstMirror() async throws {
        let updater = SoftwareUpdater(currentVersion: "1.1.479")
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("not a real app bundle".utf8).write(to: archive)
        let rememberedMirror = UserDefaults.standard.string(forKey: "updateDownloadMirrorHost")
        defer {
            if let rememberedMirror {
                UserDefaults.standard.set(rememberedMirror, forKey: "updateDownloadMirrorHost")
            } else {
                UserDefaults.standard.removeObject(forKey: "updateDownloadMirrorHost")
            }
        }
        var attempts = 0
        do {
            // 校验器会拒绝这份假档案；关键断言是：默认 isCancelled 绝不能
            // 让下载在网络请求发出之前就以 CancellationError 收场。
            _ = try await updater.downloadAndValidate(
                makeRelease(sha256: try UpdatePackageValidator.sha256(of: archive)),
                fetch: { request in
                    attempts += 1
                    return (archive, HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!)
                }
            )
            Issue.record("the fake archive must fail validation")
        } catch {
            #expect(!(error is CancellationError), "下载还没开始就被取消：isCancelled 极性传反了")
        }
        #expect(attempts == 1, "第一个镜像必须真的被尝试")
    }

    @Test func explicitCancellationStopsBeforeAnyFetch() async {
        let updater = SoftwareUpdater(currentVersion: "1.1.479")
        await #expect(throws: CancellationError.self) {
            _ = try await updater.downloadAndValidate(
                makeRelease(sha256: String(repeating: "0", count: 64)),
                isCancelled: { true },
                fetch: { _ in
                    Issue.record("cancelled download must not fetch")
                    throw URLError(.cancelled)
                }
            )
        }
    }
}
