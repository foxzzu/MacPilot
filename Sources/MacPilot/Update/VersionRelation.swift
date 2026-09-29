import Foundation

/// How a catalog release relates to the running version. Comparison is always
/// SemVer precedence through `SoftwareVersion` — never publish date, GitHub
/// list order, or release ID, none of which agree with version numbers.
enum VersionRelation: Equatable, Sendable {
    case newer
    case current
    case older
}

extension SoftwareRelease {
    func relation(to currentVersion: String) -> VersionRelation {
        guard let current = SoftwareVersion(currentVersion) else { return .current }
        if version > current { return .newer }
        if version < current { return .older }
        return .current
    }
}
