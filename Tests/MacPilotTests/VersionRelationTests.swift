import Foundation
import Testing
@testable import MacPilot

/// 方案第四、五、六节：版本关系只按 SemVer 判定，且自动更新语义保持
/// newer-only。这里覆盖 Stable/Beta、高低版本的全部组合。
struct VersionRelationTests {
    private func release(_ version: String, prerelease: Bool = false) -> SoftwareRelease {
        SoftwareRelease(
            version: SoftwareVersion(version)!,
            releaseNotes: "",
            archiveURL: URL(string: "https://github.com/misswell/MacPilot/releases/download/v\(version)/MacPilot-\(version)-arm64-macos.zip")!,
            sha256: String(repeating: "a", count: 64),
            isPrerelease: prerelease
        )
    }

    @Test func stableToNewerStableIsNewer() {
        #expect(release("1.1.480").relation(to: "1.1.479") == .newer)
    }

    @Test func stableToOlderStableIsOlder() {
        #expect(release("1.1.478").relation(to: "1.1.479") == .older)
    }

    @Test func stableToBetaIsNewerOnlyBySemVer() {
        // 1.2.0-beta.1 > 1.1.479 by SemVer precedence, even though it is a
        // prerelease: relation is purely version based.
        #expect(release("1.2.0-beta.1", prerelease: true).relation(to: "1.1.479") == .newer)
    }

    @Test func betaToNewerBetaIsNewer() {
        #expect(release("1.2.0-beta.5", prerelease: true).relation(to: "1.2.0-beta.4") == .newer)
    }

    @Test func betaToOlderBetaIsOlder() {
        #expect(release("1.2.0-beta.3", prerelease: true).relation(to: "1.2.0-beta.4") == .older)
    }

    @Test func betaToStableBelowCurrentIsOlder() {
        // 当前 1.2.0-beta.4 → Stable 1.1.479：绝不能因为"换了通道"就被当成更新。
        #expect(release("1.1.479").relation(to: "1.2.0-beta.4") == .older)
    }

    @Test func sameVersionIsCurrent() {
        #expect(release("1.1.479").relation(to: "1.1.479") == .current)
        #expect(release("v1.1.479").relation(to: "1.1.479") == .current)
    }

    @Test func unparsableCurrentVersionTreatsEverythingAsCurrent() {
        #expect(release("1.1.479").relation(to: "dev") == .current)
    }

    @Test func automaticIntentStillRequiresNewerVersion() {
        // 方案第五十四节约束 1/2：不删除 isNewer 语义，自动更新绝不降级。
        let older = release("1.1.478")
        #expect(!older.isNewer(than: "1.1.479"))
        let newer = release("1.1.480")
        #expect(newer.isNewer(than: "1.1.479"))
    }
}
