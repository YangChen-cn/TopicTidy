import Foundation
import TopicTidyCore

/// The GUI's only entry point into the core.
///
/// The former Python `gui_bridge` subprocess and its JSON transport are gone:
/// `AppService` runs in-process behind the same application lock and the same
/// validation rules. This file only maps core values onto the presentation
/// models the views already use.
actor CoreService {
    private let service = AppService()

    func dispatch(_ request: ServiceRequest) async -> ServiceResponse {
        await service.dispatch(request)
    }
}

extension Snapshot {
    init(_ session: SessionSnapshot) {
        self.init(
            plan_id: session.planID,
            members: session.members.map(Member.init),
            dismissed: session.dismissed.map { group in
                DismissedGroup(name: group.name, files: group.files.map {
                    DismissedFile(fingerprint: $0.fingerprint, name: $0.name, path: $0.path)
                })
            },
            history: session.history.map {
                Batch(id: $0.id, kind: $0.kind, status: $0.status, created_at: $0.createdAt)
            },
            preferences: Preferences(
                destination: session.preferences.destination.path,
                auto_confirm_enabled: session.preferences.autoConfirmEnabled,
                auto_confirm_threshold: session.preferences.autoConfirmThreshold
            ),
            schedule: Schedule(
                state: session.schedule.state,
                time: session.schedule.time,
                loaded: session.schedule.loaded
            ),
            downloads: session.downloads.path
        )
    }
}

extension Member {
    init(_ member: SessionMember) {
        self.init(
            id: member.id,
            name: member.name,
            path: member.path,
            topic: member.topic,
            topic_key: member.topicKey,
            confidence: member.confidence,
            excluded: member.excluded,
            applied: member.applied,
            evidence: member.evidence.map { Evidence(kind: $0.kind, strength: $0.strength, detail: $0.detail) },
            conflicts: member.conflicts
        )
    }
}

extension Move {
    init(_ move: SessionMove) {
        self.init(
            member_id: move.memberID,
            file_id: move.fileID,
            source: move.source,
            destination: move.destination,
            fingerprint: move.fingerprint,
            stale: move.stale,
            topic: move.topic,
            topic_key: move.topicKey
        )
    }

    var asSessionMove: SessionMove {
        SessionMove(memberID: member_id, fileID: file_id, source: source, destination: destination,
                    fingerprint: fingerprint, stale: stale, topic: topic, topicKey: topic_key)
    }
}
