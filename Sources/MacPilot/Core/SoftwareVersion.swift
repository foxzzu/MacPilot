import Foundation

/// SemVer precedence, retaining legacy abbreviated numeric version support.
struct SoftwareVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    private let components: [String]
    let prerelease: [String]
    let description: String
    var isPrerelease: Bool { !prerelease.isEmpty }

    init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2,
              metadata.count == 1 || Self.validIdentifiers(String(metadata[1]), numericLeadingZeros: true) else { return nil }
        let parts = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(core.count), core.allSatisfy(Self.validNumber),
              parts.count == 1 || (core.count == 3 && Self.validIdentifiers(String(parts[1]), numericLeadingZeros: false)) else { return nil }
        components = core + Array(repeating: "0", count: 3 - core.count)
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
        description = value
    }

    private static func numeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validNumber(_ value: String) -> Bool {
        numeric(value) && (value.count == 1 || value.first != "0")
    }

    private static func validIdentifiers(_ value: String, numericLeadingZeros: Bool) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { piece in
            !piece.isEmpty && piece.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } && (numericLeadingZeros || !numeric(String(piece)) || validNumber(String(piece)))
        }
    }

    private static func numberLess(_ left: String, _ right: String) -> Bool {
        left.count == right.count ? left < right : left.count < right.count
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) where left != right {
            return numberLess(left, right)
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            if numeric(left) && numeric(right) { return numberLess(left, right) }
            if numeric(left) != numeric(right) { return numeric(left) }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(components)
        hasher.combine(prerelease)
    }
}
