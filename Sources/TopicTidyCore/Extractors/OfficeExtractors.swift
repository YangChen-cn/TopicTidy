import Foundation

enum OOXML {
    static let wordprocessing = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
}

/// `_append_with_budget`: append as much as fits, report whether it was cut.
func appendWithBudget(_ parts: inout [String], _ value: String, _ remaining: Int) -> (Int, Bool) {
    if remaining <= 0 { return (0, !value.isEmpty) }
    let trimmed = Py.strip(value)
    if trimmed.isEmpty { return (remaining, false) }
    let selected = Py.prefix(trimmed, remaining)
    parts.append(selected)
    return (remaining - Py.count(selected), Py.count(trimmed) > Py.count(selected))
}

public struct DocxExtractor: DocumentExtractor {
    public let name = "docx"
    public let version = "1"

    public init() {}

    public func supports(_ path: URL) -> Bool {
        dotSuffix(path) == ".docx"
    }

    public func extract(_ path: URL, context: ExtractionContext) throws -> Extracted {
        let archive = try MiniZip(data: try Data(contentsOf: path, options: .mappedIfSafe))
        guard let document = try archive.readEntry(named: "word/document.xml") else {
            throw ExtractorError("DOCX 缺少 word/document.xml")
        }
        let body = try WordDocumentParser.parse(document)

        var parts: [String] = []
        var remaining = context.maxChars
        var truncated = false
        for paragraph in body.paragraphs {
            let (left, cut) = appendWithBudget(&parts, paragraph, remaining)
            remaining = left
            truncated = truncated || cut
            if remaining <= 0 { break }
        }
        if remaining > 0 {
            outer: for table in body.tables {
                for row in table {
                    for cell in row {
                        let (left, cut) = appendWithBudget(&parts, cell, remaining)
                        remaining = left
                        truncated = truncated || cut
                        if remaining <= 0 { break outer }
                    }
                }
            }
        }
        let combined = parts.joined(separator: "\n")
        let clipped = Py.prefix(combined, context.maxChars)
        return finalizeText(clipped, truncated: truncated || Py.count(combined) > context.maxChars)
    }
}

public struct PptxExtractor: DocumentExtractor {
    public let name = "pptx"
    public let version = "1"

    public init() {}

    public func supports(_ path: URL) -> Bool {
        dotSuffix(path) == ".pptx"
    }

    public func extract(_ path: URL, context: ExtractionContext) throws -> Extracted {
        let archive = try MiniZip(data: try Data(contentsOf: path, options: .mappedIfSafe))
        let slideNames = try PptxManifest.slideOrder(archive)

        var parts: [String] = []
        var remaining = context.maxChars
        var truncated = false
        outer: for name in slideNames {
            guard let slide = try archive.readEntry(named: name) else { continue }
            for shapeText in try SlideParser.parse(slide) where !shapeText.isEmpty {
                let (left, cut) = appendWithBudget(&parts, shapeText, remaining)
                remaining = left
                truncated = truncated || cut
                if remaining <= 0 { break outer }
            }
        }
        let combined = parts.joined(separator: "\n")
        let clipped = Py.prefix(combined, context.maxChars)
        return finalizeText(clipped, truncated: truncated || Py.count(combined) > context.maxChars)
    }
}

// MARK: - Word

struct WordBody {
    var paragraphs: [String] = []
    var tables: [[[String]]] = []
}

final class WordDocumentParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var bodyDepth: Int?
    private var tableDepth: Int?
    private var rowDepth: Int?
    private var cellDepth: Int?
    private var cellParagraphs: [String] = []
    private var paragraphDepth: Int?
    private var inText = false
    private var buffer = ""
    private var body = WordBody()

    static func parse(_ data: Data) throws -> WordBody {
        let parser = WordDocumentParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        guard xml.parse() else { throw ExtractorError("DOCX 文档 XML 解析失败") }
        return parser.body
    }

    /// Only paragraphs that are direct children of `w:body` belong to `document.paragraphs`.
    private var isTopLevelParagraph: Bool {
        guard let bodyDepth, tableDepth == nil else { return false }
        return stack.count == bodyDepth + 1
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        stack.append(elementName)
        let depth = stack.count
        switch (namespaceURI ?? "", elementName) {
        case (OOXML.wordprocessing, "body"):
            bodyDepth = depth
        case (OOXML.wordprocessing, "tbl") where bodyDepth != nil && tableDepth == nil:
            tableDepth = depth
            body.tables.append([])
        case (OOXML.wordprocessing, "tr") where tableDepth == depth - 1:
            rowDepth = depth
            body.tables[body.tables.count - 1].append([])
        case (OOXML.wordprocessing, "tc") where rowDepth == depth - 1:
            cellDepth = depth
            cellParagraphs = []
            buffer = ""
        case (OOXML.wordprocessing, "p"):
            paragraphDepth = depth
            buffer = ""
        case (OOXML.wordprocessing, "t"):
            if paragraphDepth != nil { inText = true }
        case (OOXML.wordprocessing, "tab"):
            if paragraphDepth != nil { buffer += "\t" }
        case (OOXML.wordprocessing, "br"), (OOXML.wordprocessing, "cr"):
            if paragraphDepth != nil { buffer += "\n" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let depth = stack.count
        defer { if depth > 0 { stack.removeLast() } }
        guard let bodyDepth, namespaceURI == OOXML.wordprocessing else { return }
        switch elementName {
        case "body" where depth == bodyDepth:
            self.bodyDepth = nil
        case "tbl" where depth == tableDepth:
            tableDepth = nil
        case "tr" where depth == rowDepth:
            rowDepth = nil
        case "tc" where depth == cellDepth:
            cellDepth = nil
            // `cell.text` is the cell's paragraphs joined by newlines.
            if let table = body.tables.last, let rowIndex = table.indices.last {
                body.tables[body.tables.count - 1][rowIndex]
                    .append(cellParagraphs.joined(separator: "\n"))
            }
            cellParagraphs = []
            buffer = ""
        case "p" where depth == paragraphDepth:
            let text = buffer
            buffer = ""
            paragraphDepth = nil
            if cellDepth != nil {
                cellParagraphs.append(text)
            } else if isTopLevelParagraph {
                body.paragraphs.append(text)
            }
        case "t":
            inText = false
        default:
            break
        }
    }
}

// MARK: - PowerPoint

enum PptxManifest {
    /// Slide order comes from `p:sldIdLst` resolved through package relationships.
    static func slideOrder(_ archive: MiniZip) throws -> [String] {
        guard let presentation = try archive.readEntry(named: "ppt/presentation.xml"),
              let relationships = try archive.readEntry(named: "ppt/_rels/presentation.xml.rels") else {
            return []
        }
        let targets = try RelationshipParser.parse(relationships)
        let orderedIds = try ScopeParser.parse(
            presentation, namespace: OOXML.presentation, element: "sldId",
            attributeNamespace: OOXML.relationships, attribute: "id"
        )
        var names: [String] = []
        for identifier in orderedIds {
            guard let target = targets[identifier] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst())
                : "ppt/" + target.replacingOccurrences(of: "../", with: "")
            names.append(path)
        }
        return names
    }
}

enum RelationshipParser {
    static func parse(_ data: Data) throws -> [String: String] {
        let collector = AttributeCollector(
            namespace: OOXML.packageRelationships, element: "Relationship",
            attribute: "Id", otherAttribute: "Target"
        )
        try collector.run(data)
        return collector.pairs
    }
}

enum ScopeParser {
    static func parse(_ data: Data, namespace: String, element: String,
                      attributeNamespace: String, attribute: String) throws -> [String] {
        let collector = AttributeCollector(
            namespace: namespace, element: element, attribute: attribute, otherAttribute: nil,
            attributeNamespace: attributeNamespace
        )
        try collector.run(data)
        return collector.values
    }
}

/// Collects one attribute per matching element, optionally paired with a second.
final class AttributeCollector: NSObject, XMLParserDelegate {
    private let namespace: String
    private let element: String
    private let attribute: String
    private let otherAttribute: String?
    private let attributeNamespace: String?

    var values: [String] = []
    var pairs: [String: String] = [:]

    init(namespace: String, element: String, attribute: String,
         otherAttribute: String?, attributeNamespace: String? = nil) {
        self.namespace = namespace
        self.element = element
        self.attribute = attribute
        self.otherAttribute = otherAttribute
        self.attributeNamespace = attributeNamespace
    }

    func run(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse() else { throw ExtractorError("OOXML 关系 XML 解析失败") }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard elementName == element, namespaceURI == namespace else { return }
        let value = attributeNamespace.flatMap { OOXMLLookup.attribute(attributes, namespace: $0, name: attribute) }
            ?? OOXMLLookup.attribute(attributes, namespace: nil, name: attribute)
        guard let value else { return }
        values.append(value)
        if let otherAttribute,
           let other = OOXMLLookup.attribute(attributes, namespace: nil, name: otherAttribute) {
            pairs[value] = other
        }
    }
}

enum OOXMLLookup {
    /// XMLParser reports attribute keys differently with namespace processing on
    /// and off. A namespaced request must prefer the qualified spelling, because
    /// OOXML elements frequently carry both `id` and `r:id`.
    static func attribute(_ attributes: [String: String], namespace: String?, name: String) -> String? {
        if let namespace {
            if let value = attributes[namespace + "|" + name] { return value }
            for (key, value) in attributes where key.hasSuffix(":" + name) { return value }
        }
        return attributes[name]
    }
}

/// python-pptx only reads text frames of top-level shapes; nested groups are skipped.
final class SlideParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var shapeTexts: [String] = []
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var inText = false
    private var inTextBody = false

    static func parse(_ data: Data) throws -> [String] {
        let parser = SlideParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        guard xml.parse() else { throw ExtractorError("PPTX 幻灯片 XML 解析失败") }
        return parser.shapeTexts
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let parent = stack.last
        let grandparent = stack.count >= 2 ? stack[stack.count - 2] : nil
        stack.append(elementName)
        switch (namespaceURI ?? "", elementName) {
        case (OOXML.presentation, "txBody"):
            inTextBody = parent == "sp" && grandparent == "spTree"
            if inTextBody { paragraphs = [] }
        case (OOXML.drawing, "p") where inTextBody:
            currentParagraph = ""
        case (OOXML.drawing, "t") where inTextBody:
            inText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentParagraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
        switch (namespaceURI ?? "", elementName) {
        case (OOXML.drawing, "t"):
            inText = false
        case (OOXML.drawing, "p") where inTextBody:
            paragraphs.append(currentParagraph)
        case (OOXML.presentation, "txBody") where inTextBody:
            inTextBody = false
            shapeTexts.append(paragraphs.joined(separator: "\n"))
        default:
            break
        }
    }
}
