import Foundation

public struct DailyRunResult: Sendable {
    public var scanStats: ScanStats
    public var autoConfirmEnabled: Bool
    public var planID: Int?
    public var batchID: Int?
    public var eligibleTopics: [String]?
    public var moved: Int = 0
    public var skipped: Int = 0
    public var semanticError: String?
    public var translationWarnings: [String]?

    public var asDictionary: [String: Any] {
        var result: [String: Any] = [
            "scan_stats": scanStats.asDictionary,
            "auto_confirm_enabled": autoConfirmEnabled,
            "plan_id": planID ?? NSNull(),
            "batch_id": batchID ?? NSNull(),
            "eligible_topics": eligibleTopics ?? NSNull(),
            "moved": moved,
            "skipped": skipped,
            "semantic_error": semanticError ?? NSNull(),
            "translation_warnings": translationWarnings ?? NSNull(),
        ]
        result["scan_stats"] = scanStats.asDictionary
        return result
    }
}

/// Application service suitable for the CLI, launchd, and the GUI.
public final class DailyAutomationService {
    private let db: Database
    private let settings: Settings

    public init(_ db: Database, _ settings: Settings) {
        self.db = db
        self.settings = settings
    }

    public func run(useSemantic: Bool = true) throws -> DailyRunResult {
        try AppLock.withLock(settings.dataDir) {
            let stats = try Scanner.scan(db, settings)
            if !settings.autoConfirmEnabled {
                return DailyRunResult(scanStats: stats, autoConfirmEnabled: false)
            }
            let proposal = try Workflow.createProposal(db, settings, useSemantic: useSemantic)
            let confirmed = try Workflow.autoConfirmPlan(db, settings, proposal.planID,
                                                         threshold: settings.autoConfirmThreshold)
            return DailyRunResult(
                scanStats: stats,
                autoConfirmEnabled: true,
                planID: proposal.planID,
                batchID: confirmed.batchID,
                eligibleTopics: confirmed.eligibleTopics,
                moved: confirmed.moved,
                skipped: confirmed.skipped,
                semanticError: proposal.semanticError,
                translationWarnings: proposal.translationWarnings
            )
        }
    }
}
