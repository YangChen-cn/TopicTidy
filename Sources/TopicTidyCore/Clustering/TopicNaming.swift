import CryptoKit
import Foundation

public enum TopicNaming {
    static let noise: Set<String> = TextFeatures.stopwords.union([
        "v1", "v2", "v3", "draft", "updated", "update", "new", "old", "assignment",
        "solution", "solutions", "tutorial", "lab", "material", "materials", "main", "readme",
        "md", "pdf", "docx", "pptx", "txt",
    ])

    private static let versionRegex = try! NSRegularExpression(
        pattern: "(?i)\\b(?:v(?:ersion)?\\s*)?\\d+(?:\\.\\d+)*\\b"
    )

    /// `topic_key` is durable identity; `display_name` is editable presentation.
    public static func topicKey(_ files: [IndexedFile], courseCode: String = "") -> String {
        if !courseCode.isEmpty { return "course:\(courseCode.uppercased())" }
        let identity = files.map(\.fingerprint).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "cluster:" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }

    static func cleanTokens(_ value: String) -> [String] {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let withoutCourses = CoursePattern.regex.stringByReplacingMatches(
            in: value, options: [], range: range, withTemplate: " "
        )
        let fullRange = NSRange(withoutCourses.startIndex..<withoutCourses.endIndex, in: withoutCourses)
        let withoutVersions = versionRegex.stringByReplacingMatches(
            in: withoutCourses, options: [], range: fullRange, withTemplate: " "
        )
        return TextFeatures.tokenize(withoutVersions).filter { !noise.contains($0) }
    }

    static func ngrams(_ tokens: [String]) -> [[String]] {
        var result: [[String]] = []
        let maximum = min(4, tokens.count)
        guard maximum >= 2 else { return result }
        for size in 2...maximum {
            for index in 0...(tokens.count - size) {
                result.append(Array(tokens[index..<(index + size)]))
            }
        }
        return result
    }

    static func formatPhrase(_ tokens: [String]) -> String {
        let spellings = ["freertos": "FreeRTOS", "linux": "Linux", "ml": "ML", "mlb": "MLB"]
        let words = tokens.map { token -> String in
            if let spelling = spellings[token] { return spelling }
            if token.contains(where: { $0.isNumber }) { return token.uppercased() }
            return titleCase(token)
        }
        return Py.prefix(words.joined(separator: " "), 80)
    }

    /// `str.title()` for the single tokens produced by `tokenize`.
    static func titleCase(_ token: String) -> String {
        var result = ""
        var previousWasCased = false
        for character in token {
            if character.isLetter {
                result += previousWasCased ? String(character).lowercased() : String(character).uppercased()
                previousWasCased = true
            } else {
                result.append(character)
                previousWasCased = false
            }
        }
        return result
    }

    /// Order-preserving intersection: tokens of `first` that also appear in all others.
    static func commonTokens(_ lists: [[String]]) -> [String] {
        guard let first = lists.first else { return [] }
        var common = Set(first)
        for list in lists.dropFirst() { common.formIntersection(Set(list)) }
        var seen: Set<String> = []
        var ordered: [String] = []
        for token in first where common.contains(token) && !seen.contains(token) {
            seen.insert(token)
            ordered.append(token)
        }
        return ordered
    }

    public static func displayName(_ files: [IndexedFile], courseCode: String = "") -> String {
        if !courseCode.isEmpty { return courseCode.uppercased() }

        var sources: [[String]] = []
        var documentTokens: [Set<String>] = []
        for file in files {
            let stemTokens = cleanTokens(file.path.deletingPathExtension().lastPathComponent)
            let titleTokens = cleanTokens(file.title)
            sources.append(stemTokens)
            sources.append(titleTokens)
            documentTokens.append(Set(stemTokens + titleTokens + file.keywords
                + TextFeatures.tokenize(Py.prefix(file.text, 20_000))))
        }

        let stemLists = files.map { cleanTokens($0.path.deletingPathExtension().lastPathComponent) }
        var stemCommon: [String] = []
        if !stemLists.isEmpty {
            stemCommon = Array(commonTokens(stemLists).prefix(4))
        }

        let sourceLists = files.flatMap { file in
            file.sourceURLs.map { cleanTokens(unquote(PyURL.parse($0).path)) }
        }
        if stemCommon.count <= 1 && !sourceLists.isEmpty {
            let sourceCommon = Array(commonTokens(sourceLists).prefix(4))
            if sourceCommon.count >= 2 { return formatPhrase(sourceCommon) }
        }
        if !stemCommon.isEmpty { return formatPhrase(stemCommon) }

        let titleLists = files.map { cleanTokens($0.title) }
        if !titleLists.isEmpty {
            let common = Set(commonTokens(titleLists))
            let stable = Array(titleLists[0].filter { token in
                common.contains(token) && (token.contains(where: { $0.isNumber })
                    || token == "freertos" || token == "linux")
            }.prefix(4))
            if !stable.isEmpty { return formatPhrase(stable) }
        }

        var candidates = OrderedCounter<[String]>()
        for source in sources {
            for phrase in ngrams(source) { candidates.add(phrase) }
        }
        var ranked: [(score: Double, phrase: [String])] = []
        for phrase in candidates.keys {
            let originCount = candidates.count(of: phrase)
            let phraseSet = Set(phrase)
            let coverage = documentTokens.reduce(0) { $0 + (phraseSet.isSubset(of: $1) ? 1 : 0) }
            if coverage < max(2, files.count / 2 + 1) { continue }
            let lengthBonus: Double = phrase.count == 2 ? 2.0 : (phrase.count == 3 ? 1.2 : 0.3)
            ranked.append((Double(coverage) * 10 + Double(originCount) * 2 + lengthBonus, phrase))
        }
        // `max(..., key=...)` keeps the first maximal element.
        var best: (score: Double, phrase: [String])?
        for item in ranked where best == nil || item.score > best!.score {
            best = item
        }
        if let best { return formatPhrase(best.phrase) }

        if !titleLists.isEmpty {
            let ordered = Array(commonTokens(titleLists).prefix(4))
            if !ordered.isEmpty { return formatPhrase(ordered) }
        }

        let informativeTitles = titleLists.filter { !$0.isEmpty }
        if let shortest = informativeTitles.min(by: { left, right in
            if left.count != right.count { return left.count < right.count }
            return compareTokenLists(left, right) < 0
        }) {
            return formatPhrase(Array(shortest.prefix(4)))
        }
        return "Related Documents"
    }

    /// Python list comparison: element-wise, then by length.
    static func compareTokenLists(_ left: [String], _ right: [String]) -> Int {
        for index in 0..<min(left.count, right.count) {
            let order = Py.compare(left[index], right[index])
            if order != 0 { return order }
        }
        if left.count == right.count { return 0 }
        return left.count < right.count ? -1 : 1
    }
}
