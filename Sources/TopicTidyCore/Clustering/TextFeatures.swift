import Foundation

public enum TextFeatures {
    /// Bumped when shared token/keyword behaviour changes; part of the cache key.
    public static let version = "2"

    private static let wordRegex = try! NSRegularExpression(
        pattern: "[A-Za-z][A-Za-z0-9]{1,}|[\\u4e00-\\u9fff]{2,}"
    )

    public static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "a", "an", "of", "to", "in",
        "is", "are", "was", "were", "be", "been", "being", "as", "at", "by", "on", "or",
        "if", "it", "its", "we", "you", "they", "he", "she", "them", "our", "your", "their",
        "can", "could", "will", "would", "may", "might", "should", "do", "does", "did", "not",
        "have", "has", "had", "also", "than", "then", "there", "here", "when", "where", "which",
        "who", "what", "how", "all", "any", "some", "such", "into", "over", "under", "between",
        "these", "those", "using", "used", "use", "more", "most", "other", "each", "one", "two",
        "chapter", "introduction",
        "lecture", "lectures", "notes", "slide", "slides", "document", "documents", "file",
        "course", "week", "part", "version", "final", "copy", "download", "revision", "revised",
        "的", "了", "和", "以及", "课程", "讲义", "章节", "介绍", "文档", "文件",
    ]

    public static func matches(_ value: String) -> [String] {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return wordRegex.matches(in: value, options: [], range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    public static func tokenize(_ value: String, removeStopwords: Bool = true) -> [String] {
        let tokens = matches(value).map { $0.lowercased() }
        guard removeStopwords else { return tokens }
        return tokens.filter { !stopwords.contains($0) && !isDigits($0) }
    }

    /// `str.isdigit()` for the tokens this regex can produce.
    static func isDigits(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    public static func keywords(_ text: String, limit: Int = 12) -> [String] {
        var counts = OrderedCounter<String>()
        for token in tokenize(text) { counts.add(token) }
        return counts.mostCommon(limit).map(\.0)
    }

    public static func urlTokens(_ urls: [String]) -> Set<String> {
        var values: Set<String> = []
        for url in urls {
            let parsed = PyURL.parse(url)
            values.formUnion(tokenize(unquote(parsed.path + " " + parsed.query)))
        }
        return values
    }

    /// Local filenames and stems referenced by Markdown/wiki links.
    public static func documentReferenceNames(_ text: String) -> (names: Set<String>, stems: Set<String>) {
        var references = regexMatches("\\[[^\\]]+\\]\\(([^)]+)\\)", text)
        references.append(contentsOf: regexMatches("\\[\\[([^\\]|#]+)", text))
        var names: Set<String> = []
        var stems: Set<String> = []
        for raw in references {
            let withoutFragment = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let value = Py.strip(unquote(String(withoutQuery)))
            if value.isEmpty || value.contains("://") { continue }
            let name = Py.lower(((value as NSString).lastPathComponent))
            names.insert(name)
            stems.insert((name as NSString).deletingPathExtension)
        }
        return (names, stems)
    }

    private static func regexMatches(_ pattern: String, _ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, options: [], range: range).compactMap {
            guard $0.numberOfRanges >= 2, let matchRange = Range($0.range(at: 1), in: value) else { return nil }
            return String(value[matchRange])
        }
    }
}

/// `urllib.parse.urlparse` for the shape of URLs this project reads.
public struct PyURL {
    public var scheme: String = ""
    public var netloc: String = ""
    public var path: String = ""
    public var params: String = ""
    public var query: String = ""
    public var fragment: String = ""

    public static func parse(_ rawValue: String) -> PyURL {
        // Python removes tab/newline characters before parsing.
        let value = rawValue.filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }
        var result = PyURL()
        var rest = Substring(value)

        if let hashIndex = rest.firstIndex(of: "#") {
            result.fragment = String(rest[rest.index(after: hashIndex)...])
            rest = rest[..<hashIndex]
        }
        if let queryIndex = rest.firstIndex(of: "?") {
            result.query = String(rest[rest.index(after: queryIndex)...])
            rest = rest[..<queryIndex]
        }
        if let colonIndex = rest.firstIndex(of: ":") {
            let candidate = rest[..<colonIndex]
            let isScheme = !candidate.isEmpty
                && candidate.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
                && (candidate.first?.isLetter ?? false)
            if isScheme {
                result.scheme = candidate.lowercased()
                rest = rest[rest.index(after: colonIndex)...]
            }
        }
        if rest.hasPrefix("//") {
            let afterSlashes = rest.dropFirst(2)
            let end = afterSlashes.firstIndex { "/?#".contains($0) } ?? afterSlashes.endIndex
            result.netloc = String(afterSlashes[..<end])
            rest = afterSlashes[end...]
        }
        if let semicolonIndex = rest.lastIndex(of: ";") {
            let tail = rest[rest.index(after: semicolonIndex)...]
            let tailEnd = tail.firstIndex { "/?#".contains($0) } ?? tail.endIndex
            if tailEnd == tail.endIndex {
                result.params = String(tail)
                rest = rest[..<semicolonIndex]
            }
        }
        result.path = String(rest)
        return result
    }
}

/// `urllib.parse.unquote`: percent-decoding with UTF-8 and replacement on error.
public func unquote(_ value: String) -> String {
    guard value.contains("%") else { return value }
    var bytes: [UInt8] = []
    let scalars = Array(value.unicodeScalars)
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "%", index + 2 < scalars.count,
           let high = hexValue(scalars[index + 1]), let low = hexValue(scalars[index + 2]) {
            bytes.append(UInt8(high << 4 | low))
            index += 3
            continue
        }
        bytes.append(contentsOf: Array(String(scalar).utf8))
        index += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
    switch scalar {
    case "0"..."9": return UInt8(scalar.value - 0x30)
    case "a"..."f": return UInt8(scalar.value - 0x61 + 10)
    case "A"..."F": return UInt8(scalar.value - 0x41 + 10)
    default: return nil
    }
}
