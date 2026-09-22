import Foundation

public enum JSONValue {
    /// `json.dumps(value, ensure_ascii=False, separators=(",", ":"))`
    public static func dumps(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    /// `json.loads(value)` with a default on failure.
    public static func loads(_ value: String?, default fallback: Any) -> Any {
        guard let value, !value.isEmpty, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return fallback }
        return object
    }

    public static func array(_ value: String?) -> [Any] {
        loads(value, default: []) as? [Any] ?? []
    }

    public static func stringArray(_ value: String?) -> [String] {
        array(value).map { $0 as? String ?? String(describing: $0) }
    }

    public static func dictionaryArray(_ value: String?) -> [[String: Any]] {
        array(value).compactMap { $0 as? [String: Any] }
    }

    public static func stringDictionary(_ value: String?) -> [String: Any] {
        loads(value, default: [:]) as? [String: Any] ?? [:]
    }
}

public final class Database {
    public static let schemaVersion = 6

    public static let schema = """
    CREATE TABLE IF NOT EXISTS schema_meta(version INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS app_settings(
     key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS files(
     id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, extension TEXT NOT NULL,
     size INTEGER NOT NULL, created_at REAL NOT NULL, modified_at REAL NOT NULL,
     device INTEGER NOT NULL, inode INTEGER NOT NULL, fingerprint TEXT NOT NULL,
     source_urls TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'active', last_seen REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS files_fingerprint_idx ON files(fingerprint);
    CREATE TABLE IF NOT EXISTS features(
     file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
     fingerprint TEXT NOT NULL, extractor_version TEXT NOT NULL, model_version TEXT,
     text TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', keywords TEXT NOT NULL DEFAULT '[]',
     summary TEXT NOT NULL DEFAULT '', truncated INTEGER NOT NULL DEFAULT 0,
     extraction_error TEXT, native_embedding BLOB, native_embedding_space TEXT
    );
    CREATE TABLE IF NOT EXISTS semantic_pivots(
     file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
     fingerprint TEXT NOT NULL, source_language TEXT NOT NULL, target_language TEXT NOT NULL,
     semantic_text TEXT NOT NULL, translated_text TEXT NOT NULL,
     translation_version TEXT NOT NULL, pivot_embedding BLOB, pivot_embedding_space TEXT,
     embedding_version TEXT NOT NULL, created_at REAL NOT NULL,
     PRIMARY KEY(file_id, target_language)
    );
    CREATE TABLE IF NOT EXISTS topics(
     topic_key TEXT PRIMARY KEY, display_name TEXT NOT NULL,
     folder TEXT, source TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS plans(
     id INTEGER PRIMARY KEY, created_at REAL NOT NULL, status TEXT NOT NULL, config_json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS plan_members(
     id INTEGER PRIMARY KEY, plan_id INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
     file_id INTEGER NOT NULL REFERENCES files(id), topic_key TEXT REFERENCES topics(topic_key),
     group_name TEXT, confidence REAL NOT NULL,
     reasons TEXT NOT NULL DEFAULT '[]', evidence TEXT NOT NULL DEFAULT '[]', conflicts TEXT NOT NULL DEFAULT '[]',
     excluded INTEGER NOT NULL DEFAULT 0, applied INTEGER NOT NULL DEFAULT 0,
     source_fingerprint TEXT NOT NULL, destination TEXT
    );
    CREATE TABLE IF NOT EXISTS corrections(
     id INTEGER PRIMARY KEY, created_at REAL NOT NULL, file_fingerprint TEXT NOT NULL,
     action TEXT NOT NULL, topic_name TEXT, plan_id INTEGER, active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS associations(
     id INTEGER PRIMARY KEY, topic_key TEXT NOT NULL REFERENCES topics(topic_key),
     file_fingerprint TEXT NOT NULL UNIQUE,
     confirmed_at REAL NOT NULL, active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS operation_batches(
     id INTEGER PRIMARY KEY, plan_id INTEGER, kind TEXT NOT NULL, status TEXT NOT NULL,
     created_at REAL NOT NULL, completed_at REAL
    );
    CREATE TABLE IF NOT EXISTS operation_logs(
     id INTEGER PRIMARY KEY, batch_id INTEGER NOT NULL REFERENCES operation_batches(id), file_id INTEGER,
     source TEXT NOT NULL, destination TEXT NOT NULL, fingerprint TEXT NOT NULL,
     status TEXT NOT NULL, error TEXT, created_at REAL, completed_at REAL
    );
    """

    public let connection: SQLiteConnection
    public let path: URL

    public init(path: URL) throws {
        self.path = path
        self.connection = try SQLiteConnection(path: path.path)
        try migrate()
    }

    public func close() { connection.close() }

    public func migrate() throws {
        try connection.execute(Database.schema)
        let row = try connection.query("SELECT version FROM schema_meta LIMIT 1").first
        if row == nil {
            try connection.run("INSERT INTO schema_meta(version) VALUES (?)", [Database.schemaVersion])
        } else if row![0].int != Database.schemaVersion {
            throw SQLiteError(
                message: "数据库版本 \(row![0].int) 与当前版本 \(Database.schemaVersion) 不兼容；"
                    + "测试阶段请删除本地数据库后重新 scan",
                code: -1
            )
        }
    }

    public func withTransaction<T>(_ body: (Database) throws -> T) throws -> T {
        try connection.execute("BEGIN")
        do {
            let result = try body(self)
            try connection.execute("COMMIT")
            return result
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    public func commit() throws { try connection.execute("COMMIT") }

    /// Reconcile batches interrupted between the filesystem rename and the log write.
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        let rows = try connection.query("SELECT id,plan_id,kind FROM operation_batches WHERE status='running'")
        for row in rows {
            let batchId = row["id"].int
            let planId = row["plan_id"]
            let kind = row["kind"].string
            let logs = try connection.query(
                "SELECT * FROM operation_logs WHERE batch_id=? AND status='intent'", [batchId]
            )
            for log in logs {
                let source = URL(fileURLWithPath: log["source"].string)
                let destination = URL(fileURLWithPath: log["destination"].string)
                let fileId = log["file_id"]
                let fingerprint = log["fingerprint"].string
                let status: String
                let error: String?
                if FileManager.default.fileExists(atPath: destination.path),
                   !FileManager.default.fileExists(atPath: source.path) {
                    status = "moved"
                    error = nil
                    if fileId.int != 0 && !fileId.isNull {
                        if kind == "apply" || kind == "auto_apply" {
                            try connection.run(
                                "UPDATE files SET path=?,name=?,status='organized' WHERE id=?",
                                [destination.path, destination.lastPathComponent, fileId.int]
                            )
                            let member = try connection.query(
                                """
                                SELECT topic_key,source_fingerprint FROM plan_members
                                WHERE plan_id=? AND file_id=? AND excluded=0 AND topic_key IS NOT NULL
                                ORDER BY id DESC LIMIT 1
                                """,
                                [planId.int, fileId.int]
                            ).first
                            if let member, member["source_fingerprint"].string == fingerprint {
                                try connection.run(
                                    "UPDATE plan_members SET applied=1 WHERE plan_id=? AND file_id=?",
                                    [planId.int, fileId.int]
                                )
                                try connection.run(
                                    """
                                    INSERT INTO associations(
                                    topic_key,file_fingerprint,confirmed_at,active
                                    ) VALUES(?,?,?,1)
                                    ON CONFLICT(file_fingerprint) DO UPDATE SET
                                    topic_key=excluded.topic_key,
                                    confirmed_at=excluded.confirmed_at,active=1
                                    """,
                                    [member["topic_key"].string, fingerprint, Date().timeIntervalSince1970]
                                )
                            }
                        } else if kind == "undo" {
                            try connection.run(
                                "UPDATE files SET path=?,name=?,status='active' WHERE id=?",
                                [destination.path, destination.lastPathComponent, fileId.int]
                            )
                            try connection.run(
                                "UPDATE associations SET active=0 WHERE file_fingerprint=?", [fingerprint]
                            )
                        }
                    }
                } else if FileManager.default.fileExists(atPath: source.path),
                          !FileManager.default.fileExists(atPath: destination.path) {
                    status = "not_started"
                    error = "上次运行在移动前中断"
                } else {
                    status = "ambiguous"
                    error = "源和目标状态无法自动判定"
                }
                try connection.run(
                    "UPDATE operation_logs SET status=?,error=?,completed_at=? WHERE id=?",
                    [status, error, Date().timeIntervalSince1970, log["id"].int]
                )
            }
            try connection.run(
                "UPDATE operation_batches SET status='interrupted',completed_at=? WHERE id=?",
                [Date().timeIntervalSince1970, batchId]
            )
        }
        return rows.count
    }
}
