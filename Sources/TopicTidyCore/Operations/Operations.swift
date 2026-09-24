import Foundation

public struct MovePreviewItem: Sendable {
    public var memberID: Int
    public var fileID: Int
    public var source: URL
    public var destination: URL
    public var fingerprint: String
    public var stale: Bool
    public var topic: String
    public var topicKey: String

    public var asDictionary: [String: Any] {
        [
            "member_id": memberID,
            "file_id": fileID,
            "source": source.path,
            "destination": destination.path,
            "fingerprint": fingerprint,
            "stale": stale,
            "topic": topic,
            "topic_key": topicKey,
        ]
    }
}

public struct OperationResult: Sendable {
    public var source: String
    public var destination: String
    public var status: String
    public var error: String

    public var asDictionary: [String: String] {
        ["source": source, "destination": destination, "status": status, "error": error]
    }
}

public enum Operations {
    /// Python `PurePath.suffix`: `name[i:]` when `0 < i < len(name) - 1`.
    public static func pythonSuffix(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        let index = name.distance(from: name.startIndex, to: dot)
        guard index > 0, index < name.count - 1 else { return "" }
        return String(name[dot...])
    }

    public static func pythonStem(_ name: String) -> String {
        let suffix = pythonSuffix(name)
        return suffix.isEmpty ? name : String(name.dropLast(suffix.count))
    }

    public static func safeTopicName(_ name: String) throws -> String {
        var clean = ""
        for character in name {
            clean.append(character == "/" || character == ":" || character == "\0" ? "-" : character)
        }
        clean = Py.strip(Py.strip(clean), characters: ["."])
        if clean.isEmpty || clean == "." || clean == ".." { throw OrganizerError("主题名称无效") }
        return Py.prefix(clean, 100)
    }

    public static func within(_ child: URL, _ parent: URL) -> Bool {
        let childPath = Paths.resolve(child).path
        let parentPath = Paths.resolve(parent).path
        if childPath == parentPath { return true }
        return childPath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }

    public static func uniqueDestination(_ path: URL, reserved: Set<URL> = []) throws -> URL {
        if !FileSystem.exists(path.path) && !reserved.contains(path) { return path }
        for index in 2..<10_000 {
            let name = "\(pythonStem(path.lastPathComponent)) (\(index))\(pythonSuffix(path.lastPathComponent))"
            let candidate = PyPath.join(path.deletingLastPathComponent(), name)
            if !FileSystem.exists(candidate.path) && !reserved.contains(candidate) { return candidate }
        }
        throw OrganizerError("无法为 \(path.lastPathComponent) 生成唯一目标名称")
    }

    /// `int(value)` for command arguments; invalid input is a user error.
    public static func intArgument(_ value: String) throws -> Int {
        guard let parsed = Int(value) else { throw OrganizerError("成员编号无效：\(value)") }
        return parsed
    }

    public static func ensureTopic(_ db: Database, _ displayName: String) throws -> String {
        let row = try db.connection.query(
            "SELECT topic_key FROM topics WHERE display_name=? AND active=1 ORDER BY topic_key LIMIT 1",
            [displayName]
        ).first
        if let row, !row[0].string.isEmpty { return row[0].string }
        let key = "topic:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try db.connection.run(
            "INSERT INTO topics(topic_key,display_name,source,active) VALUES(?,?,'manual',1)",
            [key, displayName]
        )
        return key
    }

    public static func planRows(_ db: Database, _ planID: Int) throws -> [Row] {
        try db.connection.query(
            """
            SELECT m.*,f.path,f.name,f.fingerprint AS current_fingerprint,f.size,f.modified_at
            FROM plan_members m JOIN files f ON f.id=m.file_id WHERE m.plan_id=? ORDER BY m.group_name,f.name
            """,
            [planID]
        )
    }

    /// A plan keeps the destination root it was created with.
    public static func planDestinationRoot(_ db: Database, _ settings: Settings, _ planID: Int) throws -> URL {
        guard let plan = try db.connection.query("SELECT config_json FROM plans WHERE id=?", [planID]).first else {
            throw OrganizerError("方案 \(planID) 不存在")
        }
        let config = JSONValue.stringDictionary(plan["config_json"].string)
        let raw = (config["organized_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? settings.organizedDir.path
        let root = Paths.resolve(Paths.expand(raw))
        if config["scan_roots"] != nil && root.path != raw {
            throw OrganizerError("方案的整理目录已被符号链接重定向")
        }
        if planScanRoots(settings, config: config).contains(where: { $0.path == root.path }) {
            throw OrganizerError("整理根目录不能直接等于扫描目录")
        }
        return root
    }

    /// A saved plan retains its source roots even if the preference changes.
    public static func planScanRoots(_ db: Database, _ settings: Settings, _ planID: Int) throws -> [URL] {
        guard let plan = try db.connection.query("SELECT config_json FROM plans WHERE id=?", [planID]).first else {
            throw OrganizerError("方案 \(planID) 不存在")
        }
        return planScanRoots(settings, config: JSONValue.stringDictionary(plan["config_json"].string))
    }

    private static func planScanRoots(_ settings: Settings, config: [String: Any]) -> [URL] {
        let stored = config["scan_roots"] as? [String] ?? []
        return stored.isEmpty ? [Paths.resolve(settings.downloads)]
            : stored.map { URL(fileURLWithPath: $0) }
    }

    public static func previewMoves(
        _ db: Database,
        _ settings: Settings,
        _ planID: Int,
        memberIDs: Set<Int>? = nil
    ) throws -> [MovePreviewItem] {
        let organizedRoot = try planDestinationRoot(db, settings, planID)
        var reserved: Set<URL> = []
        var moves: [MovePreviewItem] = []
        for row in try planRows(db, planID) {
            if row["excluded"].int != 0 || row["applied"].int != 0 || row["group_name"].isNull { continue }
            if let memberIDs, !memberIDs.contains(row["id"].int) { continue }
            let source = URL(fileURLWithPath: row["path"].string)
            var folder = PyPath.join(organizedRoot, try safeTopicName(row["group_name"].string))
            if let destination = row["destination"].optionalString, !destination.isEmpty {
                let proposedFolder = URL(fileURLWithPath: destination).deletingLastPathComponent()
                if within(proposedFolder, organizedRoot) { folder = proposedFolder }
            }
            let destination = try uniqueDestination(PyPath.join(folder, source.lastPathComponent), reserved: reserved)
            reserved.insert(destination)
            let stale = !FileSystem.exists(source.path)
                || row["source_fingerprint"].string != row["current_fingerprint"].string
            moves.append(MovePreviewItem(
                memberID: row["id"].int,
                fileID: row["file_id"].int,
                source: source,
                destination: destination,
                fingerprint: row["source_fingerprint"].string,
                stale: stale,
                topic: row["group_name"].string,
                topicKey: row["topic_key"].optionalString ?? ""
            ))
        }
        return moves
    }

    public static func applyPlan(
        _ db: Database,
        _ settings: Settings,
        _ planID: Int,
        operationKind: String = "apply",
        memberIDs: Set<Int>? = nil
    ) throws -> (batchID: Int, results: [OperationResult]) {
        let organizedRoot = try planDestinationRoot(db, settings, planID)
        let sourceRoots = try planScanRoots(db, settings, planID)
        if sourceRoots.contains(where: { FileSystem.isSymlink($0.path) || Paths.resolve($0).path != $0.path }) {
            throw OrganizerError("方案的扫描目录已被符号链接重定向")
        }
        if FileSystem.isSymlink(organizedRoot.path) {
            throw OrganizerError("整理根目录不能是符号链接")
        }
        if FileSystem.exists(organizedRoot.path) && !FileSystem.isDirectory(organizedRoot.path) {
            throw OrganizerError("整理根目录已存在，但不是目录")
        }
        if operationKind != "apply" && operationKind != "auto_apply" {
            throw OrganizerError("不支持的整理操作类型")
        }
        let moves = try previewMoves(db, settings, planID, memberIDs: memberIDs)
        if moves.isEmpty { throw OrganizerError("没有可整理的文件") }

        let now = Date().timeIntervalSince1970
        try db.connection.run(
            "INSERT INTO operation_batches(plan_id,kind,status,created_at) VALUES(?, ?, 'running', ?)",
            [planID, operationKind, now]
        )
        let batchID = db.connection.lastInsertRowID
        var results: [OperationResult] = []

        for move in moves {
            try db.connection.run(
                """
                INSERT INTO operation_logs(batch_id,file_id,source,destination,fingerprint,status,created_at)
                VALUES(?,?,?,?,?,'intent',?)
                """,
                [batchID, move.fileID, move.source.path, move.destination.path, move.fingerprint,
                 Date().timeIntervalSince1970]
            )
            let logID = db.connection.lastInsertRowID
            // Persist intent before touching the filesystem.
            let status: String
            let error: String?
            do {
                if move.stale || !FileSystem.isRegularFile(move.source.path)
                    || Scanner.fingerprint(move.source) != move.fingerprint {
                    throw OrganizerError("文件在方案生成后已改变或已消失")
                }
                if !sourceRoots.contains(where: { within(move.source, $0) })
                    || !within(move.destination, organizedRoot) {
                    throw OrganizerError("移动路径越出允许范围")
                }
                try FileManager.default.createDirectory(
                    atPath: move.destination.deletingLastPathComponent().path,
                    withIntermediateDirectories: true
                )
                guard let sourceDevice = FileSystem.device(move.source.path),
                      let destinationDevice = FileSystem.device(move.destination.deletingLastPathComponent().path),
                      sourceDevice == destinationDevice else {
                    throw OrganizerError("当前版本仅允许同卷移动；请选择同一磁盘上的整理目录")
                }
                if FileSystem.exists(move.destination.path) {
                    throw OrganizerError("目标文件已存在")
                }
                guard rename(move.source.path, move.destination.path) == 0 else {
                    throw OrganizerError("移动失败：\(String(cString: strerror(errno)))")
                }
                try db.connection.run(
                    "UPDATE files SET path=?,name=?,status='organized' WHERE id=?",
                    [move.destination.path, move.destination.lastPathComponent, move.fileID]
                )
                try db.connection.run(
                    """
                    INSERT INTO associations(topic_key,file_fingerprint,confirmed_at,active) VALUES(?,?,?,1)
                    ON CONFLICT(file_fingerprint) DO UPDATE SET topic_key=excluded.topic_key,
                    confirmed_at=excluded.confirmed_at,active=1
                    """,
                    [move.topicKey, move.fingerprint, Date().timeIntervalSince1970]
                )
                try db.connection.run("UPDATE plan_members SET applied=1 WHERE id=?", [move.memberID])
                status = "moved"
                error = nil
            } catch let failure {
                status = "skipped"
                error = String(describing: failure)
            }
            try db.connection.run(
                "UPDATE operation_logs SET status=?,error=?,completed_at=? WHERE id=?",
                [status, error, Date().timeIntervalSince1970, logID]
            )
            results.append(OperationResult(source: move.source.path, destination: move.destination.path,
                                           status: status, error: error ?? ""))
        }

        let final = results.allSatisfy { $0.status == "moved" } ? "completed" : "partial"
        try db.connection.run(
            "UPDATE operation_batches SET status=?,completed_at=? WHERE id=?",
            [final, Date().timeIntervalSince1970, batchID]
        )
        let remaining = try db.connection.scalar(
            """
            SELECT COUNT(*) FROM plan_members
            WHERE plan_id=? AND excluded=0 AND applied=0 AND group_name IS NOT NULL
            """,
            [planID]
        )?.int ?? 0
        let planStatus = remaining > 0 ? "draft" : (final == "completed" ? "applied" : "partial")
        try db.connection.run("UPDATE plans SET status=? WHERE id=?", [planStatus, planID])
        return (batchID, results)
    }

    public static func undoBatch(
        _ db: Database,
        _ settings: Settings,
        _ batchID: Int
    ) throws -> (batchID: Int, results: [OperationResult]) {
        guard let original = try db.connection.query("SELECT * FROM operation_batches WHERE id=?", [batchID]).first,
              original["kind"].string == "apply" || original["kind"].string == "auto_apply" else {
            throw OrganizerError("找不到可撤销的整理批次 \(batchID)")
        }
        let planID = original["plan_id"].int
        let organizedRoot = try planDestinationRoot(db, settings, planID)
        let sourceRoots = try planScanRoots(db, settings, planID)
        if sourceRoots.contains(where: { FileSystem.isSymlink($0.path) || Paths.resolve($0).path != $0.path }) {
            throw OrganizerError("方案的扫描目录已被符号链接重定向")
        }
        let rows = try db.connection.query(
            "SELECT * FROM operation_logs WHERE batch_id=? AND status='moved' ORDER BY id DESC", [batchID]
        )
        try db.connection.run(
            "INSERT INTO operation_batches(plan_id,kind,status,created_at) VALUES(?, 'undo', 'running', ?)",
            [planID, Date().timeIntervalSince1970]
        )
        let undoID = db.connection.lastInsertRowID
        var results: [OperationResult] = []

        for row in rows {
            let current = URL(fileURLWithPath: row["destination"].string)
            let originalPath = URL(fileURLWithPath: row["source"].string)
            let fileID = row["file_id"].int
            let fingerprint = row["fingerprint"].string
            try db.connection.run(
                """
                INSERT INTO operation_logs(batch_id,file_id,source,destination,fingerprint,status,created_at)
                VALUES(?,?,?,?,?,'intent',?)
                """,
                [undoID, fileID, current.path, originalPath.path, fingerprint, Date().timeIntervalSince1970]
            )
            let logID = db.connection.lastInsertRowID
            let status: String
            let error: String?
            do {
                if !FileSystem.isRegularFile(current.path) || Scanner.fingerprint(current) != fingerprint {
                    throw OrganizerError("已整理文件缺失或内容已改变")
                }
                if FileSystem.exists(originalPath.path) {
                    throw OrganizerError("原路径已被占用")
                }
                if !within(current, organizedRoot)
                    || !sourceRoots.contains(where: { within(originalPath, $0) }) {
                    throw OrganizerError("撤销路径越出允许范围")
                }
                try FileManager.default.createDirectory(
                    atPath: originalPath.deletingLastPathComponent().path,
                    withIntermediateDirectories: true
                )
                guard rename(current.path, originalPath.path) == 0 else {
                    throw OrganizerError("撤销失败：\(String(cString: strerror(errno)))")
                }
                try db.connection.run(
                    "UPDATE files SET path=?,name=?,status='active' WHERE id=?",
                    [originalPath.path, originalPath.lastPathComponent, fileID]
                )
                try db.connection.run("UPDATE associations SET active=0 WHERE file_fingerprint=?", [fingerprint])
                try db.connection.run(
                    "UPDATE plan_members SET applied=0 WHERE plan_id=? AND file_id=?", [planID, fileID]
                )
                status = "undone"
                error = nil
            } catch let failure {
                status = "skipped"
                error = String(describing: failure)
            }
            try db.connection.run(
                "UPDATE operation_logs SET status=?,error=?,completed_at=? WHERE id=?",
                [status, error, Date().timeIntervalSince1970, logID]
            )
            results.append(OperationResult(source: current.path, destination: originalPath.path,
                                           status: status, error: error ?? ""))
        }

        let final = results.allSatisfy { $0.status == "undone" } ? "completed" : "partial"
        try db.connection.run(
            "UPDATE operation_batches SET status=?,completed_at=? WHERE id=?",
            [final, Date().timeIntervalSince1970, undoID]
        )
        try db.connection.run("UPDATE plans SET status='draft' WHERE id=?", [planID])
        return (undoID, results)
    }

    @discardableResult
    /// Plan-scoped commands require an open draft plan; `restore-dismissed` is
    /// durable state and works even when no plan is open.
    public static func editPlan(
        _ db: Database,
        _ planID: Int?,
        command: String,
        args: [String],
        organizedDir: URL? = nil
    ) throws -> String {
        var correctionFingerprint = ""
        var correctionTopic: String?
        var action: String

        switch (command, args.count) {
        case ("dismiss-topic", 1), ("restore-topic", 1):
            guard let planID else { throw OrganizerError("方案已执行或不存在，请重新扫描生成建议") }
            let excluding = command == "dismiss-topic"
            // Dismissal is durable: it must survive the next scan, so each
            // member also gets a `dismiss` correction that clustering honours.
            let members = try db.connection.query(
                """
                SELECT m.id,m.file_id,m.group_name,f.fingerprint
                FROM plan_members m JOIN files f ON f.id=m.file_id
                WHERE m.plan_id=? AND m.topic_key=? AND m.applied=0
                """,
                [planID, args[0]]
            )
            guard !members.isEmpty else { throw OrganizerError("主题不存在或已经整理") }
            let name = members[0]["group_name"].string
            try db.connection.run(
                "UPDATE plan_members SET excluded=? WHERE plan_id=? AND topic_key=? AND applied=0",
                [excluding ? 1 : 0, planID, args[0]]
            )
            for member in members {
                let fingerprint = member["fingerprint"].string
                if fingerprint.isEmpty { continue }
                if excluding {
                    try db.connection.run(
                        "INSERT INTO corrections(created_at,file_fingerprint,action,topic_name,plan_id) VALUES(?,?,?,?,?)",
                        [Date().timeIntervalSince1970, fingerprint, "dismiss", name, planID]
                    )
                } else {
                    try db.connection.run(
                        "UPDATE corrections SET active=0 WHERE action='dismiss' AND file_fingerprint=? AND active=1",
                        [fingerprint]
                    )
                }
            }
            return excluding ? "主题已取消" : "主题已恢复"
        case ("restore-dismissed", 1):
            // Restores a topic that was dismissed in an earlier plan, where no
            // plan_members row survives to re-open.
            let name = args[0]
            let rows = try db.connection.query(
                "SELECT DISTINCT file_fingerprint FROM corrections WHERE action='dismiss' AND active=1 AND topic_name=?",
                [name]
            )
            guard !rows.isEmpty else { throw OrganizerError("没有已取消的主题 \(name)") }
            try db.connection.run(
                "UPDATE corrections SET active=0 WHERE action='dismiss' AND active=1 AND topic_name=?", [name]
            )
            if let planID {
                try db.connection.run(
                    "UPDATE plan_members SET excluded=0 WHERE plan_id=? AND group_name=? AND applied=0",
                    [planID, name]
                )
            }
            correctionTopic = name
            action = "主题 \(name) 已恢复，重新扫描后会再次提出"
        case ("rename", let count) where count >= 2:
            guard let planID else { throw OrganizerError("方案已执行或不存在，请重新扫描生成建议") }
            let old = args[0]
            let new = try safeTopicName(args[1...].joined(separator: " "))
            let keys = try db.connection.query(
                "SELECT DISTINCT topic_key FROM plan_members WHERE plan_id=? AND group_name=? AND topic_key IS NOT NULL",
                [planID, old]
            ).map { $0[0].string }
            try db.connection.run(
                "UPDATE plan_members SET group_name=?,destination=NULL WHERE plan_id=? AND group_name=?",
                [new, planID, old]
            )
            for key in keys {
                try db.connection.run(
                    "UPDATE topics SET display_name=?,source='manual' WHERE topic_key=?", [new, key]
                )
            }
            action = "主题 \(old) 已改名为 \(new)"
        case ("exclude", 1):
            guard let planID else { throw OrganizerError("方案已执行或不存在，请重新扫描生成建议") }
            guard let row = try db.connection.query(
                "SELECT source_fingerprint FROM plan_members WHERE plan_id=? AND id=?",
                [planID, try intArgument(args[0])]
            ).first else { throw OrganizerError("成员不存在") }
            correctionFingerprint = row[0].string
            try db.connection.run(
                "UPDATE plan_members SET excluded=1 WHERE plan_id=? AND id=?",
                [planID, try intArgument(args[0])]
            )
            action = "成员 \(args[0]) 已排除"
        case ("move", let count) where count >= 2:
            guard let planID else { throw OrganizerError("方案已执行或不存在，请重新扫描生成建议") }
            let topic = try safeTopicName(args[1...].joined(separator: " "))
            correctionTopic = topic
            guard let row = try db.connection.query(
                "SELECT source_fingerprint FROM plan_members WHERE plan_id=? AND id=?",
                [planID, try intArgument(args[0])]
            ).first else { throw OrganizerError("成员不存在") }
            correctionFingerprint = row[0].string
            let identity = try ensureTopic(db, topic)
            try db.connection.run(
                """
                UPDATE plan_members SET topic_key=?,group_name=?,destination=NULL,excluded=0
                  ,review_required=1,auto_eligible=0,legacy_confidence=0
                WHERE plan_id=? AND id=?
                """,
                [identity, topic, planID, try intArgument(args[0])]
            )
            action = "成员 \(args[0]) 已移至 \(topic)"
        case ("merge", let count) where count >= 2:
            guard let planID else { throw OrganizerError("方案已执行或不存在，请重新扫描生成建议") }
            let target = try safeTopicName(args[args.count - 1])
            let row = try db.connection.query(
                "SELECT topic_key FROM plan_members WHERE plan_id=? AND group_name=? AND topic_key IS NOT NULL LIMIT 1",
                [planID, target]
            ).first
            let identity: String
            if let row { identity = row[0].string } else { identity = try ensureTopic(db, target) }
            for source in args[0..<(args.count - 1)] {
                try db.connection.run(
                    "UPDATE plan_members SET topic_key=?,group_name=?,destination=NULL,review_required=1,auto_eligible=0,legacy_confidence=0 WHERE plan_id=? AND group_name=?",
                    [identity, target, planID, source]
                )
            }
            action = "已合并到 \(target)"
        case ("split", let count) where count >= 2:
            guard let planID else { throw OrganizerError("方案已执行或不存在，请重新扫描生成建议") }
            let topic = try safeTopicName(args[1...].joined(separator: " "))
            correctionTopic = topic
            guard let row = try db.connection.query(
                "SELECT source_fingerprint FROM plan_members WHERE plan_id=? AND id=?",
                [planID, try intArgument(args[0])]
            ).first else { throw OrganizerError("成员不存在") }
            correctionFingerprint = row[0].string
            let identity = try ensureTopic(db, topic)
            try db.connection.run(
                """
                UPDATE plan_members SET topic_key=?,group_name=?,destination=NULL,excluded=0
                  ,review_required=1,auto_eligible=0,legacy_confidence=0
                WHERE plan_id=? AND id=?
                """,
                [identity, topic, planID, try intArgument(args[0])]
            )
            action = "成员 \(args[0]) 已拆分到 \(topic)"
        case ("folder", 2):
            guard let planID else { throw OrganizerError("方案已执行或不存在，请重新扫描生成建议") }
            let folder = Paths.resolve(Paths.expand(args[1]))
            guard let organizedDir, within(folder, organizedDir) else {
                throw OrganizerError("主题目录必须位于当前方案的整理根目录内")
            }
            try db.connection.run(
                """
                UPDATE plan_members SET destination=? || '/' || (SELECT name FROM files WHERE id=plan_members.file_id)
                WHERE plan_id=? AND group_name=?
                """,
                [folder.path, planID, args[0]]
            )
            action = "主题 \(args[0]) 的目录设为 \(folder.path)"
        default:
            throw OrganizerError("无法识别命令或参数数量不正确")
        }

        if let planID, ["move", "merge", "split"].contains(command) {
            try db.connection.run(
                "UPDATE plan_members SET review_required=1,auto_eligible=0,legacy_confidence=0 WHERE plan_id=?",
                [planID]
            )
        }

        try db.connection.run(
            "INSERT INTO corrections(created_at,file_fingerprint,action,topic_name,plan_id) VALUES(?,?,?,?,?)",
            [Date().timeIntervalSince1970, correctionFingerprint, command, correctionTopic, planID]
        )
        return action
    }
}
