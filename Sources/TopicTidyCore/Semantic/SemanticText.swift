import Foundation

public enum SemanticText {
    public static let version = "3"
    public static let viewVersion = "1"
    public static let views = ["identity", "overview", "body"]

    public static func viewText(_ file: IndexedFile, view: String) -> String {
        switch view {
        case "identity":
            let stem = file.path.deletingPathExtension().lastPathComponent
            return Py.prefix(Py.collapseWhitespace("\(stem) \(file.title)"), 400)
        case "overview":
            return Py.prefix(Py.collapseWhitespace("\(file.summary) \(file.keywords.joined(separator: ", "))"), 600)
        case "body":
            return sample(file.text, budget: 1400)
        default: return ""
        }
    }

    static func distinctViews(_ file: IndexedFile) -> [(String, String)] {
        var seen: Set<String> = []
        return views.compactMap { view in
            let value = viewText(file, view: view)
            let key = Py.lower(value)
            guard !value.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return (view, value)
        }
    }

    /// Front/middle/tail sampling so long documents stay within the budget.
    static func sample(_ value: String, budget: Int) -> String {
        let collapsed = Py.collapseWhitespace(value)
        if Py.count(collapsed) <= budget { return collapsed }
        if budget < 12 { return Py.prefix(collapsed, budget) }
        let separatorBudget = Py.count(" … ") * 2
        let part = max(1, (budget - separatorBudget) / 3)
        let middle = max(0, Py.count(collapsed) / 2 - part / 2)
        let head = Py.prefix(collapsed, part)
        let centre = Py.slice(collapsed, middle, middle + part)
        let tail = Py.suffix(collapsed, part)
        return [head, centre, tail].joined(separator: " … ")
    }

    /// Short, stable representation used by both embedding and translation.
    public static func build(_ file: IndexedFile, maxChars: Int = 2400) -> String {
        precondition(maxChars >= 256, "semantic text budget must be at least 256 characters")

        var sections: [String] = []
        var seen: Set<String> = []
        let title = file.title.isEmpty ? file.path.deletingPathExtension().lastPathComponent : file.title
        for (label, value) in [("Title", title), ("Summary", file.summary), ("Keywords", file.keywords.joined(separator: ", "))] {
            let cleaned = Py.collapseWhitespace(value)
            let key = Py.lower(cleaned)
            if !cleaned.isEmpty && !seen.contains(key) {
                sections.append("\(label): \(cleaned)")
                seen.insert(key)
            }
        }
        let prefix = sections.joined(separator: "\n")
        let bodyBudget = max(0, maxChars - Py.count(prefix) - (prefix.isEmpty ? 0 : 2))
        let body = bodyBudget > 0 ? sample(file.text, budget: bodyBudget) : ""
        let parts = [prefix, body].filter { !$0.isEmpty }
        return Py.prefix(parts.joined(separator: "\n\n"), maxChars)
    }

    /// Choose a stable native embedding space from human-facing metadata.
    ///
    /// Code-heavy course notes frequently confuse automatic language detection.
    /// Titles and summaries are a better signal for the document's prose language.
    public static func language(_ file: IndexedFile) -> String {
        let title = file.title.isEmpty ? file.path.deletingPathExtension().lastPathComponent : file.title
        let sample = "\(title) \(Py.prefix(file.summary, 600))"
        let scalars = sample.unicodeScalars
        // The reference checks Hangul before kana regardless of position.
        if scalars.contains(where: { $0.value >= 0xAC00 && $0.value <= 0xD7AF }) { return "ko" }
        if scalars.contains(where: { $0.value >= 0x3040 && $0.value <= 0x30FF }) { return "ja" }
        var cjk = 0
        var latin = 0
        for scalar in scalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { cjk += 1 }
            if scalar.isASCII && CharacterSet.letters.contains(scalar) { latin += 1 }
        }
        if cjk >= 2 && Double(cjk) / Double(max(1, cjk + latin)) >= 0.12 { return "zh-Hans" }
        return "en"
    }

    public static func cacheVersion(_ encoderVersion: String) -> String {
        "\(encoderVersion);semantic-text:\(version)"
    }
}
