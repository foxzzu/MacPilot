import Foundation

/// Record written by MacPilotUpdater when it deliberately kept the previous
/// app bundle as a rollback copy (two-phase update success).
///
/// The updater cannot judge whether the relaunched version actually runs; it
/// only knows that `launch()` was accepted. So when a success token path was
/// supplied, the old bundle stays on disk and this record names it. The
/// relaunched app deletes the backup the next time it starts up and initializes
/// cleanly. A token that is never consumed means the new version never came up,
/// and the rollback bundle is still in place.
public struct UpdateSuccessToken: Codable, Equatable {
    public let backupPath: String
    public let targetVersion: String
    public let createdAt: Date

    public init(backupPath: String, targetVersion: String, createdAt: Date) {
        self.backupPath = backupPath
        self.targetVersion = targetVersion
        self.createdAt = createdAt
    }

    public static func write(to url: URL, backupPath: String, targetVersion: String) {
        let token = UpdateSuccessToken(
            backupPath: backupPath,
            targetVersion: targetVersion,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(token) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> UpdateSuccessToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateSuccessToken.self, from: data)
    }
}
