import Foundation

public struct ProposalResult: Sendable {
    public var planID: Int
    public var groups: [ProposedGroup]
    public var unclassified: [IndexedFile]
    public var encoderVersion: String?
    public var translationVersion: String?
    public var semanticError: String?
    public var translationWarnings: [String] = []
    public var unclassifiedReasons: [Int: String] = [:]
}

public struct AutoConfirmResult: Sendable {
    public var planID: Int
    public var eligibleTopics: [String]
    public var batchID: Int?
    public var moved: Int
    public var skipped: Int
}

public enum Workflow {
    public static func createProposal(
        _ db: Database,
        _ settings: Settings,
        useSemantic: Bool = true,
        encoder: SemanticEncoder? = nil,
        translator: TranslationBackend? = nil,
        beforeSaving: (@Sendable () -> Void)? = nil
    ) throws -> ProposalResult {
        // The native encoder is always present on macOS; the field stays for
        // callers that report a degradation.
        let semanticError: String? = nil
        let warnings = SendableBox<[String]>([])
        var activeEncoder = encoder
        var activeTranslator = translator
        if useSemantic && activeEncoder == nil {
            activeEncoder = NativeMacOSEncoder()
            activeTranslator = NativeTranslationBackend()
        }
        let result = try ClusterEngine.cluster(
            db, settings,
            encoder: useSemantic ? activeEncoder : nil,
            translator: useSemantic ? activeTranslator : nil,
            translationMessages: warnings
        )
        beforeSaving?()
        let planID = try ClusterEngine.savePlan(db, settings, groups: result.groups,
                                                unclassified: result.unclassified,
                                                unclassifiedReasons: result.unclassifiedReasons)
        var proposal = ProposalResult(
            planID: planID,
            groups: result.groups,
            unclassified: result.unclassified,
            encoderVersion: (useSemantic ? activeEncoder?.version : nil),
            translationVersion: (useSemantic ? activeTranslator?.version : nil),
            semanticError: semanticError,
            translationWarnings: warnings.value
        )
        proposal.unclassifiedReasons = result.unclassifiedReasons
        return proposal
    }

    /// Confirm and apply only complete, conflict-free groups above the threshold.
    public static func autoConfirmPlan(
        _ db: Database,
        _ settings: Settings,
        _ planID: Int,
        threshold: Double
    ) throws -> AutoConfirmResult {
        let rows = try db.connection.query(
            """
            SELECT topic_key,group_name,confidence,conflicts,evidence,excluded,
                   review_required,auto_eligible,legacy_confidence
            FROM plan_members WHERE plan_id=? AND group_name IS NOT NULL
            """,
            [planID]
        )
        var grouped: [String: [Row]] = [:]
        var groupedOrder: [String] = []
        for row in rows {
            let key = row["topic_key"].string
            if !key.isEmpty {
                if grouped[key] == nil { groupedOrder.append(key) }
                grouped[key, default: []].append(row)
            }
        }
        var eligibleKeys: Set<String> = []
        for key in groupedOrder {
            let members = grouped[key]!
            let complete = members.allSatisfy { $0["excluded"].int == 0 }
            let conflictFree = members.allSatisfy { JSONValue.array($0["conflicts"].string).isEmpty }
            let confident = (members.map { $0["legacy_confidence"].double }.min() ?? 0) >= threshold
            let oldAlgorithmEligible = members.allSatisfy {
                $0["auto_eligible"].int != 0 && $0["review_required"].int == 0
            }
            let evidence = members.flatMap { JSONValue.dictionaryArray($0["evidence"].string) }
            let usesDocumentLinks = evidence.contains {
                ($0["kind"] as? String) == "document_links" && ($0["strength"] as? String) == "strong"
            }
            let independentStrong = evidence.contains {
                autoConfirmSupportKinds.contains($0["kind"] as? String ?? "")
                    && ($0["strength"] as? String) == "strong"
            }
            let documentLinksSafe = !usesDocumentLinks || independentStrong
            if complete && conflictFree && confident && oldAlgorithmEligible && documentLinksSafe {
                eligibleKeys.insert(key)
            }
        }
        let eligibleTopics = Set(groupedOrder.filter { eligibleKeys.contains($0) }
            .flatMap { grouped[$0]!.map { $0["group_name"].string } }).sorted(by: Py.less)

        try db.withTransaction { database in
            if eligibleKeys.isEmpty {
                try database.connection.run("UPDATE plan_members SET excluded=1 WHERE plan_id=?", [planID])
            } else {
                let keys = eligibleKeys.sorted(by: Py.less)
                let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
                try database.connection.run(
                    """
                    UPDATE plan_members SET excluded=1
                    WHERE plan_id=? AND (topic_key IS NULL OR topic_key NOT IN (\(placeholders)))
                    """,
                    [planID] + keys
                )
            }
            let plan = try database.connection.query("SELECT config_json FROM plans WHERE id=?", [planID]).first
            var config = plan.map { JSONValue.stringDictionary($0["config_json"].string) } ?? [:]
            config["auto_confirm"] = [
                "threshold": threshold,
                "eligible_topic_keys": eligibleKeys.sorted(by: Py.less),
            ]
            try database.connection.run(
                "UPDATE plans SET status=?,config_json=? WHERE id=?",
                [eligibleKeys.isEmpty ? "no_auto_matches" : "auto_confirmed",
                 JSONValue.dumps(config), planID]
            )
        }

        if eligibleKeys.isEmpty {
            return AutoConfirmResult(planID: planID, eligibleTopics: [], batchID: nil, moved: 0, skipped: 0)
        }
        let (batchID, results) = try Operations.applyPlan(db, settings, planID, operationKind: "auto_apply")
        return AutoConfirmResult(
            planID: planID,
            eligibleTopics: eligibleTopics,
            batchID: batchID,
            moved: results.filter { $0.status == "moved" }.count,
            skipped: results.filter { $0.status != "moved" }.count
        )
    }
}
