import SwiftUI
import SQLite3

/// SQLite を読み取り専用で開く（セーブデータ等の閲覧用）
enum SQLiteReader {
    struct Failure: Error {
        let message: String
    }

    static func open(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "開けませんでした"
            if let db { sqlite3_close(db) }
            throw Failure(message: msg)
        }
        return opened
    }

    static func tables(_ path: String) throws -> [String] {
        try query(path, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").rows.map { $0.first ?? "" }
    }

    static func query(_ path: String, _ sql: String) throws -> (cols: [String], rows: [[String]]) {
        let db = try open(path)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let n = Int(sqlite3_column_count(stmt))
        let cols = (0..<n).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW, rows.count < 300 {
            rows.append((0..<n).map { cell(stmt, Int32($0)) })
        }
        return (cols, rows)
    }

    private static func cell(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return String(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return String(sqlite3_column_double(stmt, i))
        case SQLITE_BLOB: return "<BLOB \(sqlite3_column_bytes(stmt, i)) B>"
        case SQLITE_NULL: return "NULL"
        default:
            guard let p = sqlite3_column_text(stmt, i) else { return "" }
            let n = Int(sqlite3_column_bytes(stmt, i))
            return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
        }
    }
}

struct SQLiteBrowserView: View {
    let url: URL
    @State private var tables: [String] = []
    @State private var errorText: String?

    var body: some View {
        List {
            if let e = errorText {
                Text(e).foregroundStyle(.red)
            }
            Section("テーブル（\(tables.count)件）") {
                ForEach(tables, id: \.self) { t in
                    NavigationLink(t) {
                        SQLiteTableView(url: url, table: t)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            tables = try SQLiteReader.tables(url.path)
        } catch let e as SQLiteReader.Failure {
            errorText = e.message
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct SQLiteTableView: View {
    let url: URL
    let table: String
    @State private var cols: [String] = []
    @State private var rows: [[String]] = []
    @State private var errorText: String?

    var body: some View {
        List {
            if let e = errorText {
                Text(e).foregroundStyle(.red)
            }
            ForEach(rows.indices, id: \.self) { r in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cols.indices, id: \.self) { c in
                        HStack(alignment: .top) {
                            Text(cols[c]).font(.caption.bold()).frame(minWidth: 80, alignment: .leading)
                            Text(rows[r][c]).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle(table)
        .onAppear(perform: load)
    }

    private func load() {
        let safe = table.replacingOccurrences(of: "\"", with: "\"\"")
        do {
            let r = try SQLiteReader.query(url.path, "SELECT * FROM \"\(safe)\" LIMIT 300")
            cols = r.cols
            rows = r.rows
        } catch let e as SQLiteReader.Failure {
            errorText = e.message
        } catch {
            errorText = error.localizedDescription
        }
    }
}
