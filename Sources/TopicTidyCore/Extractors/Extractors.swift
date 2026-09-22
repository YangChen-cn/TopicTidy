import Foundation

/// Lowercased extension including the leading dot, or "" when there is none.
public func dotSuffix(_ path: URL) -> String {
    let value = path.pathExtension.lowercased()
    return value.isEmpty ? "" : "." + value
}

public struct ExtractionContext: Sendable {
    public let maxChars: Int
    public init(maxChars: Int) { self.maxChars = maxChars }
}

public protocol DocumentExtractor: Sendable {
    var name: String { get }
    var version: String { get }
    func supports(_ path: URL) -> Bool
    func extract(_ path: URL, context: ExtractionContext) throws -> Extracted
}

/// Shared normalisation for every format: collapse spaces, drop noise lines,
/// keep the first lines as a summary and derive the keyword set.
public func finalizeText(_ text: String, truncated: Bool = false, titleHint: String = "") -> Extracted {
    let normalized = collapseSpaces(text)
    let newlineSet: Set<Unicode.Scalar> = [" ", "#", "\t"]
    var lines: [String] = []
    for line in Py.splitLines(normalized) {
        // The length filter uses a full whitespace strip; the kept value does not.
        if Py.count(Py.strip(line)) >= 3 {
            lines.append(Py.strip(line, characters: newlineSet))
        }
    }
    let hint = Py.strip(titleHint)
    let title = !hint.isEmpty ? Py.prefix(hint, 180)
        : (lines.isEmpty ? "" : Py.prefix(lines[0], 180))
    let representative = Py.prefix(lines.prefix(5).joined(separator: " "), 600)
    return Extracted(
        text: normalized,
        title: title,
        keywords: TextFeatures.keywords(normalized),
        summary: representative,
        truncated: truncated
    )
}

/// `re.sub(r"[ \t]+", " ", text).strip()`
func collapseSpaces(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    var pendingSpaces = 0
    for scalar in text.unicodeScalars {
        if scalar == " " || scalar == "\t" {
            pendingSpaces += 1
            continue
        }
        if pendingSpaces > 0 {
            result.append(" ")
            pendingSpaces = 0
        }
        result.append(scalar)
    }
    return Py.strip(String(result))
}

/// Name of the extractor that owns a path; drives the cache version string.
public final class ExtractorRegistry: @unchecked Sendable {
    public static let noExtractorVersion = "metadata-only:1"

    private let extractors: [any DocumentExtractor]

    public init(_ extractors: [any DocumentExtractor]) {
        self.extractors = extractors
    }

    public static func `default`() -> ExtractorRegistry {
        ExtractorRegistry([PDFExtractor(), DocxExtractor(), PptxExtractor(), PlainTextExtractor()])
    }

    public func extractor(for path: URL) -> (any DocumentExtractor)? {
        extractors.first { $0.supports(path) }
    }

    public func cacheVersion(_ path: URL) -> String {
        let extractorVersion = extractor(for: path)
            .map { "\($0.name):\($0.version)" } ?? ExtractorRegistry.noExtractorVersion
        return "\(extractorVersion);text-features:\(TextFeatures.version)"
    }

    public func extract(_ path: URL, maxChars: Int) -> Extracted {
        guard let extractor = extractor(for: path) else { return Extracted() }
        do {
            return try extractor.extract(path, context: ExtractionContext(maxChars: maxChars))
        } catch {
            return Extracted(error: "\(type(of: error)): \(error)")
        }
    }
}
