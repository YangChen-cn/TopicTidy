import Foundation

public final class TranslationBudget {
    public let limit: Int
    public private(set) var used = 0

    public init(limit: Int = 57_600) { self.limit = limit }

    public func reserve(_ text: String) -> Bool {
        let size = Py.count(text)
        guard used + size <= limit else { return false }
        used += size
        return true
    }
}

enum SemanticViews {
    static func load(_ db: Database, _ files: inout [IndexedFile], encoderVersion: String?,
                     translatorVersion: String? = nil, includePivot: Bool = true) throws {
        guard !files.isEmpty else { return }
        for index in files.indices {
            let file = files[index]
            let rows = try db.connection.query(
                "SELECT * FROM semantic_views WHERE file_id=? AND fingerprint=? AND text_version=?",
                [file.id, file.fingerprint, SemanticText.viewVersion]
            )
            for row in rows {
                let validVersion = encoderVersion.map { row["encoder_version"].string == $0 }
                    ?? (row["encoder_version"].string == "benchmark-fixed")
                guard validVersion else { continue }
                let view = row["view"].string
                guard SemanticText.views.contains(view),
                      row["source_language"].string == (file.vectorSpace ?? SemanticText.language(file)),
                      row["semantic_text"].string == SemanticText.viewText(file, view: view) else { continue }
                let value = EncodedVector(vector: decodeVector(row["embedding"].blob),
                                          space: row["embedding_space"].optionalString)
                if row["kind"].string == "native" {
                    files[index].nativeViews[view] = value
                } else if includePivot && row["kind"].string == "pivot" {
                    if let translatorVersion,
                       row["translation_version"].string != "identity:1",
                       row["translation_version"].string != translatorVersion { continue }
                    files[index].pivotViews[view] = value
                }
            }
        }
    }

    static func encodeNative(_ db: Database, _ files: inout [IndexedFile], encoder: SemanticEncoder) throws {
        try load(db, &files, encoderVersion: encoder.version, includePivot: false)
        for index in files.indices {
            let file = files[index]
            let language = file.vectorSpace ?? SemanticText.language(file)
            let pending = SemanticText.distinctViews(file).filter { files[index].nativeViews[$0.0]?.vector == nil }
            guard !pending.isEmpty else { continue }
            let encoded = try encoder.encodeInLanguage(pending.map(\.1), language: language)
            for ((view, content), value) in zip(pending, encoded) {
                files[index].nativeViews[view] = value
                try db.connection.run(
                    """
                    INSERT INTO semantic_views(file_id,fingerprint,view,kind,semantic_text,text_version,
                      encoder_version,source_language,embedding,embedding_space)
                    VALUES(?,?,?,'native',?,?,?,?,?,?)
                    ON CONFLICT(file_id,view,kind) DO UPDATE SET
                      fingerprint=excluded.fingerprint,semantic_text=excluded.semantic_text,
                      text_version=excluded.text_version,encoder_version=excluded.encoder_version,
                      source_language=excluded.source_language,embedding=excluded.embedding,
                      embedding_space=excluded.embedding_space
                    """,
                    [file.id, file.fingerprint, view, content, SemanticText.viewVersion,
                     encoder.version, language, value.vector.map { Data(JSONValue.dumps($0).utf8) }, value.space]
                )
            }
        }
    }

    static func encodePivots(_ db: Database, _ files: inout [IndexedFile],
                             encoder: SemanticEncoder, translator: TranslationBackend,
                             selectedIDs: Set<Int>, budget: TranslationBudget) throws -> [String] {
        try load(db, &files, encoderVersion: encoder.version,
                 translatorVersion: translator.version)
        var messages: [String] = []
        let pairs = Set(files.filter { selectedIDs.contains($0.id) }
            .compactMap { file -> LanguagePair? in
                guard let source = file.vectorSpace, source != "en",
                      SemanticText.distinctViews(file).contains(where: { file.pivotViews[$0.0]?.vector == nil })
                else { return nil }
                return LanguagePair(source)
            })
        let statuses = pairs.isEmpty ? [:] : ((try? translator.statuses(Array(pairs))) ?? [:])
        for index in files.indices where selectedIDs.contains(files[index].id) {
            let file = files[index]
            guard let source = file.vectorSpace else { continue }
            for (view, content) in SemanticText.distinctViews(file) {
                if files[index].pivotViews[view]?.vector != nil { continue }
                let translated: String
                let translationVersion: String
                if source == "en" {
                    translated = content
                    translationVersion = "identity:1"
                } else {
                    guard statuses[LanguagePair(source)] == "installed" else {
                        messages.append("\(source) → en 翻译不可用：\(view)")
                        continue
                    }
                    guard budget.reserve(content) else {
                        messages.append("本轮跨语言多视图文本预算已用尽")
                        break
                    }
                    do {
                        translated = try translator.translate([content], source: source, target: "en")[0]
                    } catch {
                        messages.append("\(source) → en \(view) 翻译失败：\(error)")
                        continue
                    }
                    translationVersion = translator.version
                }
                let value: EncodedVector
                do {
                    value = try encoder.encodeInLanguage([translated], language: "en")[0]
                } catch {
                    messages.append("English pivot \(view) 编码失败：\(error)")
                    continue
                }
                files[index].pivotViews[view] = value
                try db.connection.run(
                    """
                    INSERT INTO semantic_views(file_id,fingerprint,view,kind,semantic_text,translated_text,
                     text_version,encoder_version,translation_version,source_language,embedding,embedding_space)
                    VALUES(?,?,?,'pivot',?,?,?,?,?,?,?,?)
                    ON CONFLICT(file_id,view,kind) DO UPDATE SET
                     fingerprint=excluded.fingerprint,semantic_text=excluded.semantic_text,
                     translated_text=excluded.translated_text,text_version=excluded.text_version,
                     encoder_version=excluded.encoder_version,translation_version=excluded.translation_version,
                     source_language=excluded.source_language,embedding=excluded.embedding,
                     embedding_space=excluded.embedding_space
                    """,
                    [file.id, file.fingerprint, view, content, translated, SemanticText.viewVersion,
                     encoder.version, translationVersion, source,
                     value.vector.map { Data(JSONValue.dumps($0).utf8) }, value.space]
                )
            }
        }
        return Pivot.dedupe(messages)
    }
}
