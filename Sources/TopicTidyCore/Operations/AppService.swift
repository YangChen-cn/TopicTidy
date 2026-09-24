import Foundation

/// Application service shared by the CLI, the GUI and the daily task.
///
/// This replaces the previous Python `gui_bridge` subprocess: the same
/// application services now run in-process, behind the same application lock
/// and with the same validation rules.
public struct SessionEvidence: Sendable {
    public var kind: String
    public var strength: String
    public var detail: String

    public init(kind: String, strength: String, detail: String) {
        self.kind = kind
        self.strength = strength
        self.detail = detail
    }
}

public struct SessionMember: Sendable {
    public var id: Int
    public var name: String
    public var path: String
    public var topic: String?
    public var topicKey: String?
    public var confidence: Double
    public var excluded: Bool
    public var applied: Bool
    public var evidence: [SessionEvidence]
    public var conflicts: [String]
    public var reviewRequired: Bool
    public var memberReason: String
    public var groupDiagnostics: [String: AnySendableValue]

    public init(id: Int, name: String, path: String, topic: String?, topicKey: String?,
                confidence: Double, excluded: Bool, applied: Bool,
                evidence: [SessionEvidence], conflicts: [String],
                reviewRequired: Bool = false, memberReason: String = "",
                groupDiagnostics: [String: AnySendableValue] = [:]) {
        self.id = id
        self.name = name
        self.path = path
        self.topic = topic
        self.topicKey = topicKey
        self.confidence = confidence
        self.excluded = excluded
        self.applied = applied
        self.evidence = evidence
        self.conflicts = conflicts
        self.reviewRequired = reviewRequired
        self.memberReason = memberReason
        self.groupDiagnostics = groupDiagnostics
    }
}

public struct SessionBatch: Sendable {
    public var id: Int
    public var kind: String
    public var status: String
    public var createdAt: Double
}

/// A topic the user dismissed. Dismissals are durable, so they are reported
/// even when the current plan no longer contains a row for them.
public struct SessionDismissedGroup: Sendable {
    public var name: String
    public var files: [SessionDismissedFile]

    public init(name: String, files: [SessionDismissedFile]) {
        self.name = name
        self.files = files
    }
}

public struct SessionDismissedFile: Sendable {
    public var fingerprint: String
    public var name: String
    public var path: String

    public init(fingerprint: String, name: String, path: String) {
        self.fingerprint = fingerprint
        self.name = name
        self.path = path
    }
}

public struct SessionSnapshot: Sendable {
    public var planID: Int?
    public var members: [SessionMember]
    public var dismissed: [SessionDismissedGroup]
    public var history: [SessionBatch]
    public var preferences: OrganizerPreferences
    public var schedule: ScheduleStatus
    public var downloads: URL

    public init(planID: Int?, members: [SessionMember], dismissed: [SessionDismissedGroup] = [],
                history: [SessionBatch], preferences: OrganizerPreferences,
                schedule: ScheduleStatus, downloads: URL) {
        self.planID = planID
        self.members = members
        self.dismissed = dismissed
        self.history = history
        self.preferences = preferences
        self.schedule = schedule
        self.downloads = downloads
    }
}

public struct SessionMove: Sendable, Equatable {
    public var memberID: Int
    public var fileID: Int
    public var source: String
    public var destination: String
    public var fingerprint: String
    public var stale: Bool
    public var topic: String
    public var topicKey: String

    public init(memberID: Int, fileID: Int, source: String, destination: String,
                fingerprint: String, stale: Bool, topic: String, topicKey: String) {
        self.memberID = memberID
        self.fileID = fileID
        self.source = source
        self.destination = destination
        self.fingerprint = fingerprint
        self.stale = stale
        self.topic = topic
        self.topicKey = topicKey
    }
}

/// Transport-neutral request record (the former JSON payload).
public struct ServiceRequest: Sendable {
    public var action: String = "status"
    public var planID: Int?
    public var topicKey: String?
    public var command: String?
    public var args: [String] = []
    public var confirmed = false
    public var moves: [SessionMove] = []
    public var destination: String?
    public var scanRoots: [String]?
    public var enabled: Bool?
    public var threshold: Double?
    public var at: String?
    public var batchID: Int?
    public var semantic = true

    public init() {}
}

public struct ServiceResponse: Sendable {
    public var ok: Bool
    public var error: String?
    public var snapshot: SessionSnapshot?
    public var message: String?
    public var moves: [SessionMove] = []

    public init(ok: Bool, error: String? = nil, snapshot: SessionSnapshot? = nil,
                message: String? = nil, moves: [SessionMove] = []) {
        self.ok = ok
        self.error = error
        self.snapshot = snapshot
        self.message = message
        self.moves = moves
    }
}

public actor AppService {
    private let base: Settings

    public init(base: Settings = Settings.load()) {
        self.base = base
    }

    /// Mirrors `gui_bridge.snapshot`.
    private func snapshot(_ db: Database, _ settings: Settings, planID: Int?) throws -> SessionSnapshot {
        var resolvedPlan = planID
        if resolvedPlan == nil {
            let row = try db.connection.query("SELECT id,status FROM plans ORDER BY id DESC LIMIT 1").first
            if let row, row["status"].string == "draft" { resolvedPlan = row["id"].int }
        }
        var members: [SessionMember] = []
        if let resolvedPlan {
            for row in try Operations.planRows(db, resolvedPlan) {
                members.append(SessionMember(
                    id: row["id"].int,
                    name: row["name"].string,
                    path: row["path"].string,
                    topic: row["group_name"].optionalString,
                    topicKey: row["topic_key"].optionalString,
                    confidence: row["confidence"].double,
                    excluded: row["excluded"].int != 0,
                    applied: row["applied"].int != 0,
                    evidence: JSONValue.dictionaryArray(row["evidence"].string).map {
                        SessionEvidence(kind: $0["kind"] as? String ?? "",
                                        strength: $0["strength"] as? String ?? "none",
                                        detail: $0["detail"] as? String ?? "")
                    },
                    conflicts: JSONValue.stringArray(row["conflicts"].string),
                    reviewRequired: row["review_required"].int != 0,
                    memberReason: row["member_reason"].string,
                    groupDiagnostics: JSONValue.stringDictionary(row["group_diagnostics"].string)
                        .mapValues(AnySendableValue.init)
                ))
            }
        }
        var dismissed: [SessionDismissedGroup] = []
        var dismissedIndex: [String: Int] = [:]
        var seenFingerprints: Set<String> = []
        let dismissedRows = try db.connection.query(
            """
            SELECT c.topic_name,f.name,f.path,c.file_fingerprint
            FROM corrections c JOIN files f ON f.fingerprint=c.file_fingerprint
            WHERE c.action='dismiss' AND c.active=1
            ORDER BY c.topic_name,f.name
            """
        )
        for row in dismissedRows {
            let name = row["topic_name"].optionalString ?? ""
            let fingerprint = row["file_fingerprint"].string
            guard !name.isEmpty, seenFingerprints.insert(fingerprint).inserted else { continue }
            let file = SessionDismissedFile(fingerprint: fingerprint, name: row["name"].string,
                                            path: row["path"].string)
            if let index = dismissedIndex[name] {
                dismissed[index].files.append(file)
            } else {
                dismissedIndex[name] = dismissed.count
                dismissed.append(SessionDismissedGroup(name: name, files: [file]))
            }
        }
        dismissed.sort { Py.less(Py.lower($0.name), Py.lower($1.name)) }

        let history = try db.connection.query(
            "SELECT id,kind,status,created_at FROM operation_batches ORDER BY id DESC LIMIT 40"
        ).map {
            SessionBatch(id: $0["id"].int, kind: $0["kind"].string, status: $0["status"].string,
                         createdAt: $0["created_at"].double)
        }
        return SessionSnapshot(
            planID: resolvedPlan,
            members: members,
            dismissed: dismissed,
            history: history,
            preferences: PreferenceStore(db, base: base).get(),
            schedule: LaunchAgentScheduler(settings).status(),
            downloads: settings.downloads
        )
    }

    private func planIsDraft(_ db: Database, _ planID: Int?) throws -> Bool {
        guard let planID else { return false }
        guard let plan = try db.connection.query("SELECT status FROM plans WHERE id=?", [planID]).first else {
            return false
        }
        return plan["status"].string == "draft"
    }

    /// One GUI request: same actions, messages and guards as the JSON bridge.
    public func dispatch(_ request: ServiceRequest) -> ServiceResponse {
        do {
            return try AppLock.withLock(base.dataDir) {
                try perform(request)
            }
        } catch {
            return ServiceResponse(ok: false, error: String(describing: error))
        }
    }

    private func perform(_ request: ServiceRequest) throws -> ServiceResponse {
        let db = try Database(path: base.database)
        defer { db.close() }
        _ = try db.recoverInterrupted()
        let store = PreferenceStore(db, base: base)
        var settings = store.resolvedSettings()
        var planID = request.planID
        var message: String?
        var moves: [SessionMove] = []

        // Durable commands such as `restore-dismissed` must work with no plan
        // open; everything else needs a live draft.
        let planScoped = request.action != "edit" || request.command != "restore-dismissed"
        if ["edit", "preview", "apply"].contains(request.action), planScoped {
            guard try planIsDraft(db, planID) else {
                throw OrganizerError("方案已执行或不存在，请重新扫描生成建议")
            }
        }

        switch request.action {
        case "scan":
            let stats = try Scanner.scan(db, settings, waitForStability: true)
            let result = try Workflow.createProposal(db, settings, useSemantic: request.semantic)
            planID = result.planID
            var text = "扫描完成，更新 \(stats.scanned) 个文件，提取错误 \(stats.errors) 个"
            for warning in [result.semanticError].compactMap({ $0 }) + result.translationWarnings {
                text += "；" + warning
            }
            message = text
        case "edit":
            guard let command = request.command else { throw OrganizerError("未知操作") }
            message = try Operations.editPlan(db, planID, command: command, args: request.args,
                                              organizedDir: settings.organizedDir)
        case "preview":
            var memberIDs: Set<Int>?
            if let topicKey = request.topicKey, let planID {
                memberIDs = Set(try Operations.planRows(db, planID)
                    .filter { $0["topic_key"].optionalString == topicKey }
                    .map { $0["id"].int })
            }
            moves = try Operations.previewMoves(db, settings, planID ?? 0, memberIDs: memberIDs).map(\.asSessionMove)
        case "apply":
            guard request.confirmed else { throw OrganizerError("必须先审阅移动清单并确认") }
            let requestedIDs = Set(request.moves.map(\.memberID))
            guard !requestedIDs.isEmpty else {
                throw OrganizerError("移动清单已变化，请重新预览后确认")
            }
            let pending = try Operations.planRows(db, planID ?? 0).filter {
                $0["excluded"].int == 0 && $0["applied"].int == 0 && !$0["group_name"].isNull
            }
            let allPendingIDs = Set(pending.map { $0["id"].int })
            let selectedTopics = Set(pending.filter { requestedIDs.contains($0["id"].int) }
                .map { $0["topic_key"].optionalString ?? "" })
            let selectedTopicIDs = selectedTopics.count == 1
                ? Set(pending.filter { selectedTopics.contains($0["topic_key"].optionalString ?? "") }
                    .map { $0["id"].int })
                : Set<Int>()
            guard requestedIDs == allPendingIDs || requestedIDs == selectedTopicIDs else {
                throw OrganizerError("只能确认完整主题或全部待整理主题")
            }
            let current = try Operations.previewMoves(db, settings, planID ?? 0, memberIDs: requestedIDs)
            guard request.moves == current.map(\.asSessionMove) else {
                throw OrganizerError("移动清单已变化，请重新预览后确认")
            }
            let (batch, results) = try Operations.applyPlan(db, settings, planID ?? 0, memberIDs: requestedIDs)
            var text = "批次 \(batch)：已移动 \(results.filter { $0.status == "moved" }.count)，"
                + "跳过 \(results.filter { $0.status != "moved" }.count)"
            text += results.filter { !$0.error.isEmpty }.map { "；" + $0.error }.joined()
            message = text
            if try !planIsDraft(db, planID) { planID = nil }
        case "undo":
            guard request.confirmed else { throw OrganizerError("撤销需要确认") }
            let (batch, results) = try Operations.undoBatch(db, settings, request.batchID ?? 0)
            var text = "撤销批次 \(batch)：恢复 \(results.filter { $0.status == "undone" }.count)，"
                + "跳过 \(results.filter { $0.status != "undone" }.count)"
            text += results.filter { !$0.error.isEmpty }.map { "；" + $0.error }.joined()
            message = text
        case "preferences":
            if let scanRoots = request.scanRoots {
                try store.setScanRoots(scanRoots.map { URL(fileURLWithPath: Paths.expand($0)) })
            }
            if let destination = request.destination {
                try store.setDestination(URL(fileURLWithPath: Paths.expand(destination)))
            }
            if let enabled = request.enabled {
                try store.setAutoConfirm(enabled, threshold: request.threshold)
            }
            settings = store.resolvedSettings()
            message = "设置已保存"
        case "schedule":
            let scheduler = LaunchAgentScheduler(settings)
            if request.enabled == true {
                try scheduler.enable(at: request.at ?? "09:00")
            } else {
                scheduler.disable()
            }
            message = "每日扫描设置已更新"
        case "status":
            break
        default:
            throw OrganizerError("未知操作")
        }
        return ServiceResponse(ok: true, snapshot: try snapshot(db, settings, planID: planID),
                               message: message, moves: moves)
    }
}

extension MovePreviewItem {
    /// Presentation-neutral projection of a preview row.
    public var asSessionMove: SessionMove {
        SessionMove(memberID: memberID, fileID: fileID, source: source.path,
                    destination: destination.path, fingerprint: fingerprint, stale: stale,
                    topic: topic, topicKey: topicKey)
    }
}
