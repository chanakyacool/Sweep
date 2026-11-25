import Foundation
import SQLite3

struct CleanupRecord: Identifiable, Sendable {
    let id: Int64
    let date: Date
    let section: String
    let items: Int
    let freed: Int64
    let failures: Int
}

struct RemovedItem: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    /// True while the item still sits in the Trash and its original location is free.
    let restorable: Bool
}

struct ProcessTrend: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let averageCPU: Double
    let averageMemory: Int64
    let peakMemory: Int64
    let samples: Int
}

struct DiskSample: Sendable {
    let date: Date
    let used: Int64
    let total: Int64
}

struct ScanRecord: Sendable {
    let date: Date
    let section: String
    let bytes: Int64
    let items: Int
}

struct HistoryTotals: Sendable {
    var cleanups = 0
    var items = 0
    var freed: Int64 = 0
    var freedLast30Days: Int64 = 0
}

/// Sweep's local history, kept in a SQLite database under Application Support.
/// It records what was cleaned (including every removed path), what scans found, and hourly disk usage.
final class History: @unchecked Sendable {
    static let shared = History(path: History.defaultPath)

    static var defaultPath: String {
        let directory = FS.home + "/Library/Application Support/Sweep"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory + "/history.sqlite"
    }

    /// Paths stored per cleanup; beyond this only the totals are kept.
    private static let maxItemsPerCleanup = 2_000
    private static let diskSampleInterval: TimeInterval = 3_600
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let queue = DispatchQueue(label: "local.sweep.history")
    private var database: OpaquePointer?
    private var lastDiskSample = Date.distantPast

    init(path: String) {
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            database = nil
            return
        }
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA foreign_keys = ON")
        execute("""
            CREATE TABLE IF NOT EXISTS cleanups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                section TEXT NOT NULL,
                items INTEGER NOT NULL,
                freed INTEGER NOT NULL,
                failures INTEGER NOT NULL
            )
            """)
        execute("""
            CREATE TABLE IF NOT EXISTS cleanup_items (
                cleanup_id INTEGER NOT NULL REFERENCES cleanups(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                size INTEGER NOT NULL
            )
            """)
        execute("CREATE INDEX IF NOT EXISTS cleanup_items_by_cleanup ON cleanup_items(cleanup_id)")
        execute("""
            CREATE TABLE IF NOT EXISTS scans (
                at REAL NOT NULL,
                section TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                items INTEGER NOT NULL
            )
            """)
        execute("""
            CREATE TABLE IF NOT EXISTS disk_samples (
                at REAL PRIMARY KEY,
                used INTEGER NOT NULL,
                total INTEGER NOT NULL
            )
            """)
        // Added after the first release; fails harmlessly when the column already exists.
        execute("ALTER TABLE cleanup_items ADD COLUMN trash_path TEXT")
        execute("""
            CREATE TABLE IF NOT EXISTS process_samples (
                at REAL NOT NULL,
                name TEXT NOT NULL,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL
            )
            """)
        execute("CREATE INDEX IF NOT EXISTS process_samples_by_time ON process_samples(at)")
        query("SELECT MAX(at) FROM disk_samples") { row in
            let value = sqlite3_column_double(row, 0)
            if value > 0 { self.lastDiskSample = Date(timeIntervalSince1970: value) }
        }
    }

    deinit { sqlite3_close(database) }

    // MARK: Recording

    /// Records one cleanup. Only targets that are really gone are listed as removed.
    func recordCleanup(section: String, targets: [Remover.Target], outcome: Remover.Outcome) {
        guard outcome.removed > 0 || !outcome.failures.isEmpty else { return }
        let removed = targets.filter { !FS.exists($0.path) }.prefix(Self.maxItemsPerCleanup)
        queue.sync {
            execute("BEGIN")
            run("INSERT INTO cleanups (at, section, items, freed, failures) VALUES (?, ?, ?, ?, ?)",
                [Date().timeIntervalSince1970, section, outcome.removed, outcome.freed, outcome.failures.count])
            let id = sqlite3_last_insert_rowid(database)
            for target in removed {
                run("INSERT INTO cleanup_items (cleanup_id, path, size, trash_path) VALUES (?, ?, ?, ?)",
                    [id, target.path, target.size, outcome.trashed[target.path] as Any])
            }
            execute("COMMIT")
        }
    }

    func recordScan(section: String, bytes: Int64, items: Int) {
        queue.sync {
            run("INSERT INTO scans (at, section, bytes, items) VALUES (?, ?, ?, ?)",
                [Date().timeIntervalSince1970, section, bytes, items])
        }
    }

    /// Stores disk usage at most once an hour, however often it is called.
    func sampleDisk(used: Int64, total: Int64) {
        guard total > 0 else { return }
        queue.sync {
            let now = Date()
            guard now.timeIntervalSince(lastDiskSample) >= Self.diskSampleInterval else { return }
            lastDiskSample = now
            run("INSERT OR REPLACE INTO disk_samples (at, used, total) VALUES (?, ?, ?)", [now.timeIntervalSince1970, used, total])
            // A year of hourly samples is plenty for trends.
            run("DELETE FROM disk_samples WHERE at < ?", [now.timeIntervalSince1970 - 366 * 86_400])
        }
    }

    // MARK: Reading

    func cleanups(limit: Int = 200) -> [CleanupRecord] {
        queue.sync {
            var records: [CleanupRecord] = []
            query("SELECT id, at, section, items, freed, failures FROM cleanups ORDER BY at DESC LIMIT ?", [limit]) { row in
                records.append(CleanupRecord(
                    id: sqlite3_column_int64(row, 0),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    section: String(cString: sqlite3_column_text(row, 2)),
                    items: Int(sqlite3_column_int64(row, 3)),
                    freed: sqlite3_column_int64(row, 4),
                    failures: Int(sqlite3_column_int64(row, 5))))
            }
            return records
        }
    }

    func removedItems(cleanup id: Int64) -> [RemovedItem] {
        queue.sync {
            var items: [RemovedItem] = []
            query("SELECT path, size, trash_path FROM cleanup_items WHERE cleanup_id = ? ORDER BY size DESC", [id]) { row in
                let path = String(cString: sqlite3_column_text(row, 0))
                let trashPath = sqlite3_column_text(row, 2).map { String(cString: $0) }
                items.append(RemovedItem(path: path, size: sqlite3_column_int64(row, 1),
                                         restorable: trashPath.map { FS.exists($0) && !FS.exists(path) } ?? false))
            }
            return items
        }
    }

    /// Moves a cleanup's items from the Trash back to where they were. Returns how many were restored and how many failed.
    func putBack(cleanup id: Int64) -> (restored: Int, failed: Int) {
        var pairs: [(path: String, trashPath: String)] = []
        queue.sync {
            query("SELECT path, trash_path FROM cleanup_items WHERE cleanup_id = ? AND trash_path IS NOT NULL", [id]) { row in
                pairs.append((String(cString: sqlite3_column_text(row, 0)), String(cString: sqlite3_column_text(row, 1))))
            }
        }
        var restored = 0, failed = 0
        let manager = FileManager.default
        for pair in pairs where FS.exists(pair.trashPath) && !FS.exists(pair.path) {
            do {
                try manager.createDirectory(atPath: (pair.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try manager.moveItem(atPath: pair.trashPath, toPath: pair.path)
                restored += 1
                queue.sync { run("UPDATE cleanup_items SET trash_path = NULL WHERE cleanup_id = ? AND path = ?", [id, pair.path]) }
            } catch {
                failed += 1
            }
        }
        return (restored, failed)
    }

    // MARK: Process trends

    func recordProcesses(_ rows: [(name: String, cpu: Double, memory: Int64)]) {
        guard !rows.isEmpty else { return }
        queue.sync {
            let now = Date().timeIntervalSince1970
            execute("BEGIN")
            for row in rows {
                run("INSERT INTO process_samples (at, name, cpu, memory) VALUES (?, ?, ?, ?)", [now, row.name, row.cpu, row.memory])
            }
            run("DELETE FROM process_samples WHERE at < ?", [now - 14 * 86_400])
            execute("COMMIT")
        }
    }

    /// Average and peak resource use per application over the last `hours` hours.
    func processTrends(hours: Int) -> [ProcessTrend] {
        queue.sync {
            var trends: [ProcessTrend] = []
            let sql = "SELECT name, AVG(cpu), AVG(memory), MAX(memory), COUNT(*) FROM process_samples "
                + "WHERE at >= ? GROUP BY name ORDER BY AVG(memory) DESC LIMIT 60"
            query(sql, [Date().timeIntervalSince1970 - Double(hours) * 3_600]) { row in
                trends.append(ProcessTrend(name: String(cString: sqlite3_column_text(row, 0)),
                                           averageCPU: sqlite3_column_double(row, 1),
                                           averageMemory: Int64(sqlite3_column_double(row, 2)),
                                           peakMemory: sqlite3_column_int64(row, 3),
                                           samples: Int(sqlite3_column_int64(row, 4))))
            }
            return trends
        }
    }

    func totals() -> HistoryTotals {
        queue.sync {
            var totals = HistoryTotals()
            query("SELECT COUNT(*), COALESCE(SUM(items), 0), COALESCE(SUM(freed), 0) FROM cleanups") { row in
                totals.cleanups = Int(sqlite3_column_int64(row, 0))
                totals.items = Int(sqlite3_column_int64(row, 1))
                totals.freed = sqlite3_column_int64(row, 2)
            }
            query("SELECT COALESCE(SUM(freed), 0) FROM cleanups WHERE at >= ?", [Date().timeIntervalSince1970 - 30 * 86_400]) { row in
                totals.freedLast30Days = sqlite3_column_int64(row, 0)
            }
            return totals
        }
    }

    /// Bytes freed per calendar day for the last `days` days, oldest first, including empty days.
    func freedPerDay(days: Int) -> [(day: Date, freed: Int64)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var buckets = [Date: Int64]()
        queue.sync {
            query("SELECT at, freed FROM cleanups WHERE at >= ?", [first.timeIntervalSince1970]) { row in
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)))
                buckets[day, default: 0] += sqlite3_column_int64(row, 1)
            }
        }
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: first).map { ($0, buckets[$0] ?? 0) }
        }
    }

    func diskSamples(days: Int) -> [DiskSample] {
        queue.sync {
            var samples: [DiskSample] = []
            query("SELECT at, used, total FROM disk_samples WHERE at >= ? ORDER BY at", [Date().timeIntervalSince1970 - Double(days) * 86_400]) { row in
                samples.append(DiskSample(date: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
                                          used: sqlite3_column_int64(row, 1), total: sqlite3_column_int64(row, 2)))
            }
            return samples
        }
    }

    /// The most recent scan result for each section.
    func latestScans() -> [ScanRecord] {
        queue.sync {
            var records: [ScanRecord] = []
            query("SELECT MAX(at), section, bytes, items FROM scans GROUP BY section ORDER BY bytes DESC") { row in
                records.append(ScanRecord(date: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
                                          section: String(cString: sqlite3_column_text(row, 1)),
                                          bytes: sqlite3_column_int64(row, 2), items: Int(sqlite3_column_int64(row, 3))))
            }
            return records
        }
    }

    func clear() {
        queue.sync {
            for table in ["cleanup_items", "cleanups", "scans", "disk_samples", "process_samples"] { execute("DELETE FROM \(table)") }
            lastDiskSample = .distantPast
        }
    }

    // MARK: SQLite plumbing

    private func execute(_ sql: String) {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ values: [Any]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Any] = []) {
        guard let statement = prepare(sql, values) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func query(_ sql: String, _ values: [Any] = [], _ row: (OpaquePointer) -> Void) {
        guard let statement = prepare(sql, values) else { return }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        sqlite3_finalize(statement)
    }
}
