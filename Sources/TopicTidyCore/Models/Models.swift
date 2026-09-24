import Foundation

public struct Extracted: Sendable, Equatable {
    public var text: String = ""
    public var title: String = ""
    public var keywords: [String] = []
    public var summary: String = ""
    public var truncated: Bool = false
    public var error: String?

    public init(text: String = "", title: String = "", keywords: [String] = [],
                summary: String = "", truncated: Bool = false, error: String? = nil) {
        self.text = text
        self.title = title
        self.keywords = keywords
        self.summary = summary
        self.truncated = truncated
        self.error = error
    }
}

public struct IndexedFile: Sendable {
    public var id: Int
    public var path: URL
    public var name: String
    public var fileExtension: String
    public var size: Int
    public var createdAt: Double
    public var modifiedAt: Double
    public var device: Int
    public var inode: Int
    public var fingerprint: String
    public var sourceURLs: [String]
    public var text: String
    public var title: String
    public var keywords: [String]
    public var summary: String
    public var extractionError: String?
    public var vector: [Double]?
    public var vectorSpace: String?
    public var pivotVector: [Double]?
    public var pivotSpace: String?
    public var pivotSourceLanguage: String?
    public var pivotEmbeddingVersion: String?
    public var pivotTranslationVersion: String?
    public var nativeViews: [String: EncodedVector] = [:]
    public var pivotViews: [String: EncodedVector] = [:]

    public init(id: Int, path: URL, name: String, fileExtension: String, size: Int,
                createdAt: Double, modifiedAt: Double, device: Int, inode: Int,
                fingerprint: String, sourceURLs: [String], text: String, title: String,
                keywords: [String], summary: String, extractionError: String?,
                vector: [Double]? = nil, vectorSpace: String? = nil,
                pivotVector: [Double]? = nil, pivotSpace: String? = nil,
                pivotSourceLanguage: String? = nil, pivotEmbeddingVersion: String? = nil,
                pivotTranslationVersion: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.fileExtension = fileExtension
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.device = device
        self.inode = inode
        self.fingerprint = fingerprint
        self.sourceURLs = sourceURLs
        self.text = text
        self.title = title
        self.keywords = keywords
        self.summary = summary
        self.extractionError = extractionError
        self.vector = vector
        self.vectorSpace = vectorSpace
        self.pivotVector = pivotVector
        self.pivotSpace = pivotSpace
        self.pivotSourceLanguage = pivotSourceLanguage
        self.pivotEmbeddingVersion = pivotEmbeddingVersion
        self.pivotTranslationVersion = pivotTranslationVersion
    }
}

public struct Evidence: Sendable, Equatable {
    public var kind: String
    public var strength: String
    public var score: Double?
    public var detail: String

    public init(kind: String, strength: String, score: Double?, detail: String) {
        self.kind = kind
        self.strength = strength
        self.score = score
        self.detail = detail
    }

    public var asDictionary: [String: Any] {
        [
            "kind": kind,
            "strength": strength,
            "score": score.map { rounded($0, 3) } ?? NSNull(),
            "detail": detail,
        ]
    }
}

public struct ProposedGroup: Sendable {
    public var topicKey: String
    public var displayName: String
    public var confidence: Double
    public var files: [IndexedFile]
    public var evidence: [Evidence]
    public var conflicts: [String]
    public var reviewRequired: Bool = false
    public var autoEligible: Bool = false
    public var legacyConfidence: Double = 0
    public var diagnostics: [String: AnySendableValue] = [:]
    public var memberReasons: [Int: String] = [:]

    public init(topicKey: String, displayName: String, confidence: Double,
                files: [IndexedFile], evidence: [Evidence], conflicts: [String] = []) {
        self.topicKey = topicKey
        self.displayName = displayName
        self.confidence = confidence
        self.files = files
        self.evidence = evidence
        self.conflicts = conflicts
    }

    /// Compatibility alias for the CLI and operation code.
    public var name: String { displayName }

    public var reasons: [String] {
        evidence.filter { $0.strength != "none" }.map(\.detail)
    }

    public func asDictionary(destination: URL) -> [String: Any] {
        [
            "topic_id": topicKey,
            "display_name": displayName,
            "name": displayName,
            "confidence": rounded(confidence, 3),
            "confidence_note": "启发式评分，不代表统计准确率",
            "destination": destination.appendingPathComponent(displayName).path,
            "files": files.map { $0.path.path },
            "reasons": reasons,
            "evidence": evidence.map(\.asDictionary),
            "conflicts": conflicts,
            "review_required": reviewRequired,
            "group_diagnostics": diagnostics.mapValues(\.value),
            "member_reasons": Dictionary(uniqueKeysWithValues: files.map { ($0.name, memberReasons[$0.id] ?? "核心成员") }),
        ]
    }
}

/// Small type-erased value so proposal diagnostics remain Sendable.
public struct AnySendableValue: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
}

/// `round(value, digits)` with Python's round-half-to-even behaviour.
public func rounded(_ value: Double, _ digits: Int) -> Double {
    guard value.isFinite else { return value }
    let factor = pow(10.0, Double(digits))
    let scaled = value * factor
    let floorValue = scaled.rounded(.down)
    let fraction = scaled - floorValue
    var result: Double
    if fraction == 0.5 {
        result = (floorValue.truncatingRemainder(dividingBy: 2) == 0) ? floorValue : floorValue + 1
    } else {
        result = scaled.rounded()
    }
    return result / factor
}
