import Foundation
import SQLite3

/// Consistent, corruption-safe copies of a SQLite database via the online
/// backup API.
///
/// A plain `FileManager.copyItem` of a SQLite file can silently discard
/// committed transactions that still live in the WAL. The backup API copies
/// the logical database content instead, and the follow-up
/// `PRAGMA integrity_check` proves the copy is readable before anybody relies
/// on it. Shared by the store migration and the Version Manager downgrade
/// snapshots; anything that snapshots user data must go through here.
public enum SQLiteSnapshot {
    public enum SnapshotError: Error, Equatable {
        case openFailed(Int32)
        case backupInitFailed(Int32)
        case backupFailed(Int32)
        case integrityCheckFailed
    }

    /// Copies the logical content of the database at `source` into a new file
    /// at `destination` and verifies the result with `PRAGMA integrity_check`.
    /// The destination must not exist yet.
    public static func create(from source: URL, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        var input: OpaquePointer?
        var output: OpaquePointer?
        defer {
            if let input { sqlite3_close(input) }
            if let output { sqlite3_close(output) }
        }
        try check(sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil), SnapshotError.openFailed)
        try check(
            sqlite3_open_v2(
                destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
            ),
            SnapshotError.openFailed
        )
        sqlite3_busy_timeout(input, 1000)
        sqlite3_busy_timeout(output, 1000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw SnapshotError.backupInitFailed(sqlite3_errcode(output))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else {
            if step != SQLITE_OK { try check(step, SnapshotError.backupFailed) }
            try check(finish, SnapshotError.backupFailed)
            return
        }
        try check(finish, SnapshotError.backupFailed)
        // 在输出连接关闭前做 integrity_check：WAL 库的第二连接此刻还看不到
        // 未 checkpoint 的内容。语句必须立刻 finalize——未走完的语句会持有
        // 读事务，导致随后的 journal 模式切换被拒绝。
        var statement: OpaquePointer?
        var integrityOK = false
        if sqlite3_prepare_v2(output, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW,
           let result = sqlite3_column_text(statement, 0),
           String(cString: result) == "ok" {
            integrityOK = true
        }
        sqlite3_finalize(statement)
        statement = nil
        guard integrityOK else {
            throw SnapshotError.integrityCheckFailed
        }
        // 把副本归一为普通 journal 模式：WAL 模式持久写在库头里，而快照文件
        // 日后经常以只读方式验证（只读连接无法初始化 WAL 的 shm 文件）。
        // 自包含的单文件才是可靠的恢复点。只影响副本，不影响源库。
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, &errorPointer) == SQLITE_OK else {
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SnapshotError.integrityCheckFailed
        }
    }

    /// Whether the database at `url` passes `PRAGMA integrity_check`.
    public static func integrityCheckSucceeds(_ url: URL) -> Bool {
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok" else {
            return false
        }
        return true
    }

    private static func check(_ result: Int32, _ makeError: (Int32) -> SnapshotError) throws {
        guard result == SQLITE_OK else { throw makeError(result) }
    }
}
