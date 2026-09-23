import Foundation

public enum AppDefaults {
    public static let appName = "DownloadsOrganizer"
    public static let organizedName = "Organized"
    public static let crossLanguageTimeWindowSeconds: Double = 14 * 24 * 60 * 60
    public static let incompleteSuffixes: Set<String> = [".crdownload", ".download", ".part", ".tmp"]
}

/// Course-shaped identifiers found in file names, stems and source URLs.
///
/// Kept byte-for-byte compatible with the Python reference, including its
/// Unicode `\s` class, because course codes decide cluster identity.
public enum CoursePattern {
    public static let regex = try! NSRegularExpression(
        pattern: "(?<![A-Z0-9])([A-Z]{2,8})[\\s\\u000B\\u001C-\\u001F\\u0085_-]?(\\d{4})(?!\\d)",
        options: [.caseInsensitive]
    )

    public static let nonCoursePrefixes: Set<String> = [
        "AUTUMN", "FALL", "SPRING", "SUMMER", "WINTER", "TERM", "SEMESTER",
        "LECTURE", "CHAPTER",
    ]

    public static let bodyCoursePrefixes: Set<String> = [
        "ACCT", "AI", "BIO", "BUS", "CHEM", "CIVL", "COMM", "COMP", "CS", "CSE",
        "DATA", "ECE", "ECON", "EE", "ELEC", "ENGG", "FIN", "INFO", "LAW", "MATH",
        "MECH", "MED", "PHYS", "STAT",
    ]

    /// Every `(prefix, number)` pair in `value`, in match order.
    public static func matches(_ value: String) -> [(prefix: String, number: String)] {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let prefixRange = Range(match.range(at: 1), in: value),
                  let numberRange = Range(match.range(at: 2), in: value)
            else { return nil }
            return (String(value[prefixRange]), String(value[numberRange]))
        }
    }
}

/// Reject common year-shaped citations before treating text as a course code.
public func isCourseCandidate(_ prefix: String, _ number: String) -> Bool {
    if CoursePattern.nonCoursePrefixes.contains(prefix) { return false }
    guard let value = Int(number) else { return false }
    return !(1900...2099).contains(value)
}

/// Use a strict academic-prefix allowlist for codes found inside documents.
public func isBodyCourseCandidate(_ prefix: String, _ number: String) -> Bool {
    CoursePattern.bodyCoursePrefixes.contains(prefix) && isCourseCandidate(prefix, number)
}

public func normalizeCourse(_ value: String) -> String {
    for match in CoursePattern.matches(value) {
        let prefix = match.prefix.uppercased()
        if isCourseCandidate(prefix, match.number) { return "\(prefix)\(match.number)" }
    }
    return ""
}

public func allCourses(_ value: String) -> Set<String> {
    var result: Set<String> = []
    for match in CoursePattern.matches(value) {
        let prefix = match.prefix.uppercased()
        if isCourseCandidate(prefix, match.number) { result.insert("\(prefix)\(match.number)") }
    }
    return result
}

public func bodyCourses(_ value: String) -> Set<String> {
    var result: Set<String> = []
    for match in CoursePattern.matches(value) {
        let prefix = match.prefix.uppercased()
        if isBodyCourseCandidate(prefix, match.number) { result.insert("\(prefix)\(match.number)") }
    }
    return result
}

public struct Settings: Sendable, Equatable {
    public var downloads: URL
    /// Top-level folders to index. Downloads remains the default and the
    /// fallback location for the organized destination.
    public var scanRoots: [URL]
    public var dataDir: URL
    public var organizedName: String = AppDefaults.organizedName
    public var organizedRoot: URL?
    public var autoConfirmEnabled: Bool = false
    public var autoConfirmThreshold: Double = 0.92
    public var maxTextChars: Int = 120_000
    public var stableSeconds: Double = 2.0
    public var clusterThreshold: Double = 0.64
    public var courseAttachThreshold: Double = 0.70
    public var crossLanguageCandidateNeighbors: Int = 2
    public var crossLanguageTranslationLimit: Int = 24

    public init(downloads: URL, dataDir: URL) {
        self.downloads = downloads
        self.scanRoots = [downloads]
        self.dataDir = dataDir
    }

    public var database: URL { dataDir.appendingPathComponent("organizer.sqlite3") }

    public var organizedDir: URL {
        organizedRoot ?? downloads.appendingPathComponent(organizedName)
    }

    public func with(scanRoots: [URL]? = nil, organizedRoot: URL? = nil, autoConfirmEnabled: Bool? = nil,
                     autoConfirmThreshold: Double? = nil) -> Settings {
        var copy = self
        if let scanRoots { copy.scanRoots = scanRoots }
        if let organizedRoot { copy.organizedRoot = organizedRoot }
        if let autoConfirmEnabled { copy.autoConfirmEnabled = autoConfirmEnabled }
        if let autoConfirmThreshold { copy.autoConfirmThreshold = autoConfirmThreshold }
        return copy
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> Settings {
        let downloads = Paths.expand(environment["DOWNLOADS_ORGANIZER_DOWNLOADS"] ?? "~/Downloads")
        let data = Paths.expand(environment["DOWNLOADS_ORGANIZER_HOME"] ?? Paths.defaultDataDir)
        var settings = Settings(downloads: Paths.resolve(downloads), dataDir: Paths.resolve(data))
        if let destination = environment["DOWNLOADS_ORGANIZER_DESTINATION"], !destination.isEmpty {
            settings.organizedRoot = Paths.resolve(Paths.expand(destination))
        }
        return settings
    }
}

public enum Paths {
    /// Same location `platformdirs.user_data_dir` returns on macOS.
    public static var defaultDataDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(AppDefaults.appName)").path
    }

    public static func expand(_ value: String) -> String {
        (value as NSString).expandingTildeInPath
    }

    /// `Path.resolve()`: absolute, symlink-free, `.`/`..` collapsed.
    ///
    /// Foundation's `resolvingSymlinksInPath` deliberately leaves `/var` and
    /// `/tmp` alone; Python's `realpath`-based resolve does not, so use
    /// `realpath(3)` for the existing prefix and canonicalise the rest lexically.
    public static func resolve(_ value: String) -> URL {
        let expanded = expand(value)
        if let resolved = realpathString(expanded) { return URL(fileURLWithPath: resolved) }
        var remaining: [String] = []
        var current = expanded
        while current.count > 1, !FileManager.default.fileExists(atPath: current) {
            remaining.insert((current as NSString).lastPathComponent, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        var base = realpathString(current) ?? current
        for component in remaining {
            base = (base as NSString).appendingPathComponent(component)
        }
        return URL(fileURLWithPath: (base as NSString).standardizingPath)
    }

    public static func resolve(_ url: URL) -> URL {
        resolve(url.path)
    }

    static func realpathString(_ value: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(value, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }
}
