import CryptoKit
import Foundation

public struct ScanStats: Sendable, Equatable {
    public var scanned = 0
    public var unchanged = 0
    public var skipped = 0
    public var errors = 0

    public var asDictionary: [String: Int] {
        ["scanned": scanned, "unchanged": unchanged, "skipped": skipped, "errors": errors]
    }
}

public enum Scanner {
    public static func fingerprint(_ path: URL, chunkSize: Int = 1024 * 1024) -> String {
        var hasher = SHA256()
        guard let handle = try? FileHandle(forReadingFrom: path) else { return "" }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Top-level regular files in every configured root, sorted stably.
    public static func candidates(_ settings: Settings) throws -> [URL] {
        var result: [URL] = []
        for root in settings.scanRoots {
            guard FileSystem.isDirectory(root.path) && !FileSystem.isSymlink(root.path) else {
                throw OrganizerError("扫描目录不可用：\(root.path)")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            for name in names {
                if name.hasPrefix(".") { continue }
                let path = root.appendingPathComponent(name)
                if FileSystem.isSymlink(path.path) { continue }
                if !FileSystem.isRegularFile(path.path) { continue }
                if AppDefaults.incompleteSuffixes.contains("." + path.pathExtension.lowercased()) { continue }
                result.append(path)
            }
        }
        return result.sorted {
            let left = Py.lower($0.lastPathComponent), right = Py.lower($1.lastPathComponent)
            return left == right ? Py.less($0.path, $1.path) : Py.less(left, right)
        }
    }

    static func isStable(_ first: FileStat?, _ second: FileStat?) -> Bool {
        guard let first, let second else { return false }
        return first.size == second.size
            && first.modifiedSeconds == second.modifiedSeconds
            && first.modifiedNanoseconds == second.modifiedNanoseconds
    }

    public static func scan(
        _ db: Database,
        _ settings: Settings,
        waitForStability: Bool = false,
        registry: ExtractorRegistry = .default()
    ) throws -> ScanStats {
        var stats = ScanStats()
        var seen: Set<String> = []
        let now = Date().timeIntervalSince1970
        let paths = try candidates(settings)
        var initialStats: [String: FileStat] = [:]
        if waitForStability {
            for path in paths { initialStats[path.path] = FileStat(path: path.path) }
            if settings.stableSeconds > 0 { Thread.sleep(forTimeInterval: settings.stableSeconds) }
        }

        for path in paths {
            do {
                if waitForStability && !isStable(initialStats[path.path], FileStat(path: path.path)) {
                    stats.skipped += 1
                    continue
                }
                guard let fileStat = FileStat(path: path.path) else {
                    stats.errors += 1
                    continue
                }
                let resolved = Paths.resolve(path).path
                seen.insert(resolved)
                let existing = try db.connection.query("SELECT * FROM files WHERE path=?", [resolved]).first
                let extractorVersion = registry.cacheVersion(path)
                var existingFeature: Row?
                if let existing {
                    existingFeature = try db.connection.query(
                        "SELECT fingerprint,extractor_version FROM features WHERE file_id=?",
                        [existing["id"].int]
                    ).first
                }
                let sameFileState = existing != nil
                    && existing!["size"].int == fileStat.size
                    && existing!["modified_at"].double == fileStat.modifiedAt
                let cacheCurrent = sameFileState
                    && existingFeature != nil
                    && existingFeature!["fingerprint"].string == existing!["fingerprint"].string
                    && existingFeature!["extractor_version"].string == extractorVersion
                if cacheCurrent {
                    try db.connection.run(
                        "UPDATE files SET status='active', last_seen=? WHERE id=?",
                        [now, existing!["id"].int]
                    )
                    stats.unchanged += 1
                    continue
                }
                let digest = sameFileState ? existing!["fingerprint"].string : fingerprint(path)
                let urls = SourceMetadata.sourceURLs(path)
                try db.withTransaction { database in
                    try database.connection.run(
                        """
                        INSERT INTO files(path,name,extension,size,created_at,modified_at,device,inode,fingerprint,source_urls,status,last_seen)
                        VALUES(?,?,?,?,?,?,?,?,?,?, 'active',?)
                        ON CONFLICT(path) DO UPDATE SET name=excluded.name,extension=excluded.extension,size=excluded.size,
                        created_at=excluded.created_at,modified_at=excluded.modified_at,device=excluded.device,
                        inode=excluded.inode,fingerprint=excluded.fingerprint,source_urls=excluded.source_urls,status='active',last_seen=excluded.last_seen
                        """,
                        [resolved, path.lastPathComponent, "." + path.pathExtension.lowercased(),
                         fileStat.size, fileStat.createdAt, fileStat.modifiedAt, fileStat.device,
                         fileStat.inode, digest, JSONValue.dumps(urls), now]
                    )
                    guard let idRow = try database.connection.query("SELECT id FROM files WHERE path=?", [resolved]).first else {
                        return
                    }
                    let fileId = idRow["id"].int
                    let cached = try database.connection.query(
                        "SELECT 1 FROM features WHERE file_id=? AND fingerprint=? AND extractor_version=?",
                        [fileId, digest, extractorVersion]
                    ).first
                    if cached == nil {
                        let result = registry.extract(path, maxChars: settings.maxTextChars)
                        try database.connection.run(
                            """
                            INSERT INTO features(file_id,fingerprint,extractor_version,text,title,keywords,summary,truncated,extraction_error)
                            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(file_id) DO UPDATE SET
                            fingerprint=excluded.fingerprint,extractor_version=excluded.extractor_version,model_version=NULL,
                            text=excluded.text,title=excluded.title,keywords=excluded.keywords,summary=excluded.summary,
                            truncated=excluded.truncated,extraction_error=excluded.extraction_error,
                            native_embedding=NULL,native_embedding_space=NULL
                            """,
                            [fileId, digest, extractorVersion, result.text, result.title,
                             JSONValue.dumps(result.keywords), result.summary,
                             result.truncated ? 1 : 0, result.error]
                        )
                        try database.connection.run("DELETE FROM semantic_pivots WHERE file_id=?", [fileId])
                        if result.error != nil { stats.errors += 1 }
                    }
                }
                stats.scanned += 1
            } catch {
                stats.errors += 1
            }
        }

        if seen.isEmpty {
            try db.connection.run("UPDATE files SET status='missing' WHERE status='active'")
        } else {
            let identifiers = Array(seen)
            var index = 0
            let chunkSize = 900
            var keep: [String] = []
            while index < identifiers.count {
                let chunk = Array(identifiers[index..<min(index + chunkSize, identifiers.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try db.connection.query(
                    "SELECT path FROM files WHERE status='active' AND path IN (\(placeholders))", chunk
                )
                keep.append(contentsOf: rows.map { $0["path"].string })
                index += chunkSize
            }
            if keep.isEmpty {
                try db.connection.run("UPDATE files SET status='missing' WHERE status='active'")
            } else {
                let placeholders = Array(repeating: "?", count: keep.count).joined(separator: ",")
                try db.connection.run(
                    "UPDATE files SET status='missing' WHERE status='active' AND path NOT IN (\(placeholders))",
                    keep
                )
            }
        }
        return stats
    }
}

public struct OrganizerError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
