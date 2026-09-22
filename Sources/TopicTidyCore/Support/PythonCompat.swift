import Foundation

/// Small helpers that reproduce CPython string semantics.
///
/// The clustering rules were written against Python and are being migrated
/// one-to-one. Lengths, slicing, whitespace splitting and string ordering must
/// therefore follow CPython (code points, not grapheme clusters) so that the
/// same fixture produces the same grouping on both sides of the migration.
public enum Py {
    /// Characters for which CPython's `str.isspace()` is true.
    public static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// `len(value)` in CPython: the number of Unicode code points.
    public static func count(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    /// `value[:limit]` in CPython.
    public static func prefix(_ value: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        let scalars = value.unicodeScalars
        guard scalars.count > limit else { return value }
        return String(String.UnicodeScalarView(scalars.prefix(limit)))
    }

    /// `value[-limit:]` in CPython.
    public static func suffix(_ value: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        let scalars = value.unicodeScalars
        guard scalars.count > limit else { return value }
        return String(String.UnicodeScalarView(scalars.suffix(limit)))
    }

    /// `value[start:end]` in CPython, with negative indices.
    public static func slice(_ value: String, _ start: Int, _ end: Int) -> String {
        let scalars = Array(value.unicodeScalars)
        let total = scalars.count
        var lower = start < 0 ? max(0, total + start) : min(start, total)
        var upper = end < 0 ? max(0, total + end) : min(end, total)
        if upper < lower { upper = lower }
        if lower > total { lower = total }
        return String(String.UnicodeScalarView(scalars[lower..<upper]))
    }

    /// `str.split()` with no separator: split on runs of whitespace, drop empties.
    public static func splitWhitespace(_ value: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if isSpace(scalar) {
                if !current.isEmpty {
                    result.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// `" ".join(value.split())` — collapse all whitespace runs into single spaces.
    public static func collapseWhitespace(_ value: String) -> String {
        splitWhitespace(value).joined(separator: " ")
    }

    /// `str.splitlines()`: split on every Python line boundary and keep no ends.
    public static func splitLines(_ value: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                result.append(String(current)); current = String.UnicodeScalarView(); index += 1
            case 0x0D:
                result.append(String(current)); current = String.UnicodeScalarView()
                index += (index + 1 < scalars.count && scalars[index + 1].value == 0x0A) ? 2 : 1
            default:
                current.append(scalar); index += 1
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// `str.strip()` with no argument.
    public static func strip(_ value: String) -> String {
        strip(value, characters: nil)
    }

    /// `str.strip(chars)`: drop any leading/trailing character from `characters`.
    public static func strip(_ value: String, characters: Set<Unicode.Scalar>?) -> String {
        let scalars = Array(value.unicodeScalars)
        func matches(_ scalar: Unicode.Scalar) -> Bool {
            guard let characters else { return isSpace(scalar) }
            return characters.contains(scalar)
        }
        var start = 0
        var end = scalars.count
        while start < end, matches(scalars[start]) { start += 1 }
        while end > start, matches(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// `str.lower()` / `str.casefold()` for the identifiers this project compares.
    public static func lower(_ value: String) -> String {
        value.lowercased()
    }

    /// Python compares `str` by code point; Swift compares by Unicode canonical order.
    public static func less(_ left: String, _ right: String) -> Bool {
        compare(left, right) < 0
    }

    public static func compare(_ left: String, _ right: String) -> Int {
        let leftScalars = left.unicodeScalars
        let rightScalars = right.unicodeScalars
        var leftIndex = leftScalars.startIndex
        var rightIndex = rightScalars.startIndex
        while leftIndex < leftScalars.endIndex, rightIndex < rightScalars.endIndex {
            let leftValue = leftScalars[leftIndex].value
            let rightValue = rightScalars[rightIndex].value
            if leftValue != rightValue { return leftValue < rightValue ? -1 : 1 }
            leftScalars.formIndex(after: &leftIndex)
            rightScalars.formIndex(after: &rightIndex)
        }
        if leftIndex < leftScalars.endIndex { return 1 }
        if rightIndex < rightScalars.endIndex { return -1 }
        return 0
    }
}

public extension Array {
    /// Python's `sorted(key=...)` is stable; Swift's `sorted(by:)` is not.
    func pySorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { left, right in
                if areInIncreasingOrder(left.element, right.element) { return true }
                if areInIncreasingOrder(right.element, left.element) { return false }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}

/// `pathlib`-style path joining: literal separators, no percent encoding.
public enum PyPath {
    public static func join(_ base: URL, _ component: String) -> URL {
        if component.isEmpty { return base }
        if component.hasPrefix("/") { return URL(fileURLWithPath: component) }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return URL(fileURLWithPath: prefix + component)
    }

    public static func join(_ base: URL, _ components: [String]) -> URL {
        components.reduce(base) { join($0, $1) }
    }

    public static func join(_ base: URL, _ first: String, _ rest: String...) -> URL {
        join(base, [first] + rest)
    }
}

/// Mirrors `collections.Counter`, including insertion-ordered tie breaking.
public struct OrderedCounter<Key: Hashable> {
    private var counts: [Key: Int] = [:]
    private var order: [Key] = []

    public init() {}

    public mutating func add(_ key: Key, _ amount: Int = 1) {
        if counts[key] == nil { order.append(key) }
        counts[key, default: 0] += amount
    }

    public func count(of key: Key) -> Int { counts[key] ?? 0 }

    public var keys: [Key] { order }

    /// `Counter.most_common(limit)`: count descending, first-seen order on ties.
    public func mostCommon(_ limit: Int? = nil) -> [(Key, Int)] {
        let ranked = order.enumerated()
            .map { (element: $0.element, count: counts[$0.element] ?? 0, index: $0.offset) }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.index < right.index
            }
            .map { ($0.element, $0.count) }
        guard let limit, limit >= 0 else { return ranked }
        return Array(ranked.prefix(limit))
    }

    public var total: Int { counts.values.reduce(0, +) }
}
