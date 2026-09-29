import Foundation
import SQLite3
import Testing
import XCTest
@testable import MacPilotRightClickKit

/// 方案第十七、四十九节：SQLite 快照必须使用 Backup API，包含 WAL 中已提交
/// 的事务，且禁止只测试空数据库。
final class SQLiteSnapshotTests: XCTestCase {
    private func execute(_ statements: [String], on database: OpaquePointer) {
        for statement in statements {
            var errorPointer: UnsafeMutablePointer<CChar>?
            XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, &errorPointer), SQLITE_OK)
            if let errorPointer { sqlite3_free(errorPointer) }
        }
    }

    private func open(_ url: URL, flags: Int32) -> OpaquePointer? {
        var database: OpaquePointer?
        sqlite3_open_v2(url.path, &database, flags, nil)
        return database
    }

    private func columnValues(_ query: String, database: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    func testSnapshotIncludesCommittedWALTransactionsAndSurvivesLaterWrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("live.sqlite")
        let snapshot = directory.appendingPathComponent("snapshot.sqlite")

        // WAL 模式 + 已提交事务：提交内容还在 WAL 里，普通文件复制会丢。
        guard let live = open(source, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) else {
            return XCTFail("could not open live database")
        }
        execute([
            "PRAGMA journal_mode=WAL;",
            "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);",
            "INSERT INTO settings (key, value) VALUES ('before_snapshot', 'yes');"
        ], on: live)

        try SQLiteSnapshot.create(from: source, to: snapshot)
        XCTAssertTrue(SQLiteSnapshot.integrityCheckSucceeds(snapshot))

        // 快照之后又写入了新数据；恢复时必须回到快照时间点。
        execute(["INSERT INTO settings (key, value) VALUES ('after_snapshot', 'yes');"], on: live)
        sqlite3_close(live)

        // 用快照覆盖原库（与恢复流程一致：staging 后 replace）。
        let restored = directory.appendingPathComponent("restored.sqlite")
        try FileManager.default.copyItem(at: snapshot, to: restored)

        guard let reopened = open(restored, flags: SQLITE_OPEN_READONLY) else {
            return XCTFail("could not open restored database")
        }
        defer { sqlite3_close(reopened) }
        let keys = columnValues("SELECT key FROM settings ORDER BY key;", database: reopened)
        XCTAssertEqual(keys, ["before_snapshot"])
        XCTAssertTrue(SQLiteSnapshot.integrityCheckSucceeds(restored))
    }

    func testSnapshotOfMissingSourceThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.sqlite")
        let destination = directory.appendingPathComponent("out.sqlite")
        XCTAssertThrowsError(try SQLiteSnapshot.create(from: missing, to: destination))
    }
}
