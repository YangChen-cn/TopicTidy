import Foundation
import Translation

public struct SystemVersion {
    /// `platform.mac_ver()[0]`: the marketing version without the patch component.
    public static var release: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}

/// Small lock-protected box so an async Apple framework call can hand a value
/// back to the synchronous core.
public final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ value: Value) { storage = value }

    public var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    public func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

public struct LanguagePair: Hashable, Sendable {
    public var source: String
    public var target: String

    public init(_ source: String, _ target: String = "en") {
        self.source = source
        self.target = target
    }
}

public protocol TranslationBackend: AnyObject {
    var version: String { get }
    func statuses(_ pairs: [LanguagePair]) throws -> [LanguagePair: String]
    func translate(_ texts: [String], source: String, target: String) throws -> [String]
}

/// Installed-only Apple Translation backend; it never requests assets.
public final class NativeTranslationBackend: TranslationBackend, @unchecked Sendable {
    public init() {}

    public var version: String {
        "apple-translation:\(SystemVersion.release):native"
    }

    static func statusName(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return "installed"
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        @unknown default: return "unsupported"
        }
    }

    public func statuses(_ pairs: [LanguagePair]) throws -> [LanguagePair: String] {
        guard !pairs.isEmpty else { return [:] }
        guard #available(macOS 15.0, *) else {
            throw SemanticEncodingError("Apple Translation 需要 macOS 15 或更高版本")
        }
        let unique = Self.uniqued(pairs)
        let result = SendableBox<[LanguagePair: String]>([:])
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let availability = LanguageAvailability()
            for pair in unique {
                let status = await availability.status(
                    from: Locale.Language(identifier: pair.source),
                    to: Locale.Language(identifier: pair.target)
                )
                result.update { $0[pair] = Self.statusName(status) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    public func translate(_ texts: [String], source: String, target: String) throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard #available(macOS 26.0, *) else {
            throw SemanticEncodingError("命令行仅安装模式翻译需要 macOS 26 或更高版本")
        }
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let semaphore = DispatchSemaphore(value: 0)
        let translations = SendableBox<[String]?>(nil)
        let failure = SendableBox<String?>(nil)
        Task {
            let availability = LanguageAvailability()
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
            guard status == .installed else {
                failure.value = "语言对状态为 \(Self.statusName(status))"
                semaphore.signal()
                return
            }
            // `installedSource` is restricted to already-installed assets and
            // therefore cannot display or initiate a download prompt.
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            var output: [String] = []
            do {
                for text in texts {
                    output.append(try await session.translate(text).targetText)
                }
                translations.value = output
            } catch {
                failure.value = String(describing: error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let message = failure.value { throw SemanticEncodingError(message) }
        guard let values = translations.value, values.count == texts.count else {
            throw SemanticEncodingError("Apple Translation 返回了无效翻译结果")
        }
        return values
    }

    static func uniqued(_ pairs: [LanguagePair]) -> [LanguagePair] {
        var seen: Set<LanguagePair> = []
        var result: [LanguagePair] = []
        for pair in pairs where !seen.contains(pair) {
            seen.insert(pair)
            result.append(pair)
        }
        return result
    }
}

public enum Pivot {
    /// Populate missing English pivots for selected candidate files only.
    ///
    /// Returns human-readable degradation messages instead of failing proposal
    /// generation when a language asset is absent or translation is unavailable.
    public static func ensurePivotEmbeddings(
        _ db: Database,
        _ files: inout [IndexedFile],
        encoder: SemanticEncoder,
        translator: TranslationBackend,
        target: String = "en"
    ) throws -> [String] {
        var pending: [IndexedFile] = []
        for file in files {
            if !file.text.isEmpty && !(file.vectorSpace ?? "").isEmpty && (file.pivotVector ?? []).isEmpty {
                pending.append(file)
            }
        }
        if pending.isEmpty { return [] }

        var messages: [String] = []
        var translated: [Int: (String, String)] = [:]
        var fresh: [IndexedFile] = []
        for file in pending {
            let currentSemanticText = SemanticText.build(file)
            let cached = try db.connection.query(
                """
                SELECT source_language,semantic_text,translated_text,translation_version
                FROM semantic_pivots WHERE file_id=? AND fingerprint=? AND target_language=?
                """,
                [file.id, file.fingerprint, target]
            ).first
            if let cached, cached["source_language"].string == file.vectorSpace,
               cached["semantic_text"].string == currentSemanticText {
                translated[file.id] = (cached["translated_text"].string, cached["translation_version"].string)
            } else {
                fresh.append(file)
            }
        }

        var statuses: [LanguagePair: String] = [:]
        let pairs = fresh.compactMap { file -> LanguagePair? in
            let space = file.vectorSpace ?? ""
            return space != target ? LanguagePair(space, target) : nil
        }
        do {
            statuses = try translator.statuses(pairs)
        } catch {
            messages.append(String(describing: error))
        }

        for file in fresh {
            let semanticText = SemanticText.build(file)
            let source = file.vectorSpace ?? ""
            if source == target {
                translated[file.id] = (semanticText, "identity:1")
                continue
            }
            let pair = LanguagePair(source, target)
            let state = statuses[pair] ?? "unsupported"
            if state != "installed" {
                let label = state == "supported" ? "未安装" : "不可用"
                messages.append("\(source) → \(target) 翻译\(label)")
                continue
            }
            do {
                let value = try translator.translate([semanticText], source: source, target: target)[0]
                translated[file.id] = (value, translator.version)
            } catch {
                messages.append("\(source) → \(target) 翻译失败：\(error)")
            }
        }

        if translated.isEmpty { return dedupe(messages) }

        let selected = pending.filter { translated[$0.id] != nil }
        var encoded: [EncodedVector] = []
        do {
            encoded = try encoder.encodeInLanguage(selected.map { translated[$0.id]!.0 }, language: target)
        } catch {
            messages.append("English pivot 编码失败：\(error)")
            return dedupe(messages)
        }
        let cacheVersion = SemanticText.cacheVersion(encoder.version)
        for (file, result) in zip(selected, encoded) {
            guard let index = files.firstIndex(where: { $0.id == file.id }) else { continue }
            let (translatedText, translationVersion) = translated[file.id]!
            files[index].pivotVector = result.vector
            files[index].pivotSpace = result.space
            files[index].pivotSourceLanguage = file.vectorSpace
            files[index].pivotEmbeddingVersion = cacheVersion
            try db.connection.run(
                """
                INSERT INTO semantic_pivots(
                file_id,fingerprint,source_language,target_language,semantic_text,translated_text,
                translation_version,pivot_embedding,pivot_embedding_space,embedding_version,created_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(file_id,target_language) DO UPDATE SET
                fingerprint=excluded.fingerprint,source_language=excluded.source_language,
                semantic_text=excluded.semantic_text,translated_text=excluded.translated_text,
                translation_version=excluded.translation_version,pivot_embedding=excluded.pivot_embedding,
                pivot_embedding_space=excluded.pivot_embedding_space,
                embedding_version=excluded.embedding_version,created_at=excluded.created_at
                """,
                [file.id, file.fingerprint, file.vectorSpace, target, SemanticText.build(file),
                 translatedText, translationVersion,
                 result.vector.map { Data(JSONValue.dumps($0).utf8) }, result.space,
                 cacheVersion, Date().timeIntervalSince1970]
            )
        }
        return dedupe(messages)
    }

    static func dedupe(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

public enum TranslationStatus {
    public static func status(languages: [String] = ["zh-Hans", "ja", "ko"]) -> [String: Any] {
        let backend = NativeTranslationBackend()
        do {
            let states = try backend.statuses(languages.map { LanguagePair($0) })
            var pairs: [String: String] = [:]
            for language in languages {
                pairs["\(language) -> en"] = states[LanguagePair(language)] ?? "unsupported"
            }
            return [
                "backend": "apple-translation",
                "prepared": true,
                "download_required": false,
                "pairs": pairs,
            ]
        } catch {
            return [
                "backend": "apple-translation",
                "prepared": false,
                "download_required": false,
                "pairs": Dictionary(uniqueKeysWithValues: languages.map { ("\($0) -> en", "unavailable") }),
                "error": String(describing: error),
            ]
        }
    }
}
