import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public let code: Int32
    public var description: String { message }
}

/// A materialised result row. Values are copied out of SQLite immediately, so
/// a row stays valid after its statement is finalised.
public struct Row: Sendable {
    let columnNames: [String: Int32]
    let values: [Value]

    public subscript(index: Int32) -> Value {
        guard index >= 0, Int(index) < values.count else { return .null }
        return values[Int(index)]
    }

    public subscript(name: String) -> Value {
        guard let index = columnNames[name] else { return .null }
        return self[index]
    }

    public var columnNamesInOrder: [String] { Array(columnNames.keys) }
}

public struct Value: Sendable {
    public enum Storage: Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    let storage: Storage

    public static let null = Value(storage: .null)

    init(storage: Storage) { self.storage = storage }

    public var isNull: Bool {
        if case .null = storage { return true }
        return false
    }

    public var int: Int {
        switch storage {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value) ?? 0
        default: return 0
        }
    }

    public var double: Double {
        switch storage {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        case .text(let value): return Double(value) ?? 0
        default: return 0
        }
    }

    public var string: String {
        switch storage {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .blob(let value): return String(decoding: value, as: UTF8.self)
        case .null: return ""
        }
    }

    public var optionalString: String? { isNull ? nil : string }

    public var optionalDouble: Double? { isNull ? nil : double }

    public var blob: Data? {
        switch storage {
        case .blob(let value): return value
        case .text(let value): return Data(value.utf8)
        case .null: return nil
        default: return Data()
        }
    }
}

/// Thin SQLite3 wrapper. It is deliberately not `Sendable`: callers hold it
/// inside one actor or one process-wide lock, matching the reference design.
public final class SQLiteConnection {
    var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            throw SQLiteError(message: message, code: SQLITE_ERROR)
        }
        self.handle = handle
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA journal_mode=WAL")
    }

    deinit { close() }

    public func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    private func fail() -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 错误"
        return SQLiteError(message: message, code: handle.map { sqlite3_errcode($0) } ?? SQLITE_ERROR)
    }

    /// Run one or more statements without parameters, ignoring rows.
    public func execute(_ sql: String) throws {
        guard let handle else { throw fail() }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite 错误"
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SQLiteError(message: message, code: sqlite3_errcode(handle))
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [Any?] = []) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw fail() }
        return Int(sqlite3_last_insert_rowid(handle))
    }

    public func query(_ sql: String, _ parameters: [Any?] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        var names: [String: Int32] = [:]
        let count = sqlite3_column_count(statement)
        for index in 0..<count {
            if let name = sqlite3_column_name(statement, index) {
                names[String(cString: name)] = index
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            var values: [Value] = []
            values.reserveCapacity(Int(count))
            for index in 0..<count { values.append(Self.materialize(statement, index)) }
            rows.append(Row(columnNames: names, values: values))
        }
        return rows
    }

    public func scalar(_ sql: String, _ parameters: [Any?] = []) throws -> Value? {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.materialize(statement, 0)
    }

    static func materialize(_ statement: OpaquePointer, _ index: Int32) -> Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return Value(storage: .integer(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
            return Value(storage: .real(sqlite3_column_double(statement, index)))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            return Value(storage: .text(String(cString: pointer)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
                return Value(storage: .blob(Data()))
            }
            return Value(storage: .blob(Data(bytes: pointer, count: count)))
        default:
            return .null
        }
    }

    public func changes() -> Int { Int(sqlite3_changes(handle)) }

    /// `cursor.lastrowid`
    public var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    private func prepare(_ sql: String, _ parameters: [Any?]) throws -> OpaquePointer {
        guard let handle else { throw fail() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw fail()
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case nil, is NSNull:
                sqlite3_bind_null(statement, index)
            case let value as Int:
                sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, index, value)
            case let value as Double:
                sqlite3_bind_double(statement, index, value)
            case let value as Bool:
                sqlite3_bind_int64(statement, index, value ? 1 : 0)
            case let value as Data:
                if value.isEmpty {
                    sqlite3_bind_blob(statement, index, nil, 0, SQLITE_TRANSIENT)
                } else {
                    value.withUnsafeBytes { buffer in
                        _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                    }
                }
            case let value as String:
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            default:
                sqlite3_bind_text(statement, index, String(describing: parameter!), -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }
}
