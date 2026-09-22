import Foundation

public struct PlainTextExtractor: DocumentExtractor {
    public let name = "plain-text"
    public let version = "1"
    public static let suffixes: Set<String> = [".txt", ".md", ".markdown"]

    public init() {}

    public func supports(_ path: URL) -> Bool {
        PlainTextExtractor.suffixes.contains(dotSuffix(path))
    }

    public func extract(_ path: URL, context: ExtractionContext) throws -> Extracted {
        let text = try Self.readText(path, budget: context.maxChars + 1)
        let truncated = Py.count(text) > context.maxChars
        return finalizeText(Py.prefix(text, context.maxChars), truncated: truncated)
    }

    /// Read at most `budget` characters, decoding invalid bytes as U+FFFD.
    static func readText(_ path: URL, budget: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        // Four bytes per code point is an upper bound for UTF-8.
        let limit = max(0, budget) * 4
        let data = try handle.read(upToCount: limit) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
