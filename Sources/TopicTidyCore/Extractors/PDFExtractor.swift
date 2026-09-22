import Foundation
import PDFKit

/// Return front, representative middle, and tail pages in reading order.
public func sampledPageIndices(_ pageCount: Int) -> [Int] {
    if pageCount <= 8 { return Array(0..<max(0, pageCount)) }
    let front = [0, 1, 2]
    let middle = [0.25, 0.5, 0.75].map { Int(rounded(Double(pageCount - 1) * $0, 0)) }
    let tail = [pageCount - 2, pageCount - 1]
    // `dict.fromkeys`: keep first occurrence in reading order.
    var seen: Set<Int> = []
    var ordered: [Int] = []
    for index in front + middle + tail where !seen.contains(index) {
        seen.insert(index)
        ordered.append(index)
    }
    return ordered
}

public struct PDFExtractor: DocumentExtractor {
    public let name = "pdf"
    public let version = "2"

    public init() {}

    public func supports(_ path: URL) -> Bool {
        dotSuffix(path) == ".pdf"
    }

    public func extract(_ path: URL, context: ExtractionContext) throws -> Extracted {
        guard let document = PDFDocument(url: path) else {
            throw ExtractorError("无法读取 PDF")
        }
        if document.isEncrypted {
            if !document.unlock(withPassword: "") {
                throw ExtractorError("PDF 已加密")
            }
        }
        let pageCount = document.pageCount
        let indices = sampledPageIndices(pageCount)
        if indices.isEmpty { return Extracted() }

        // Front pages receive twice the per-page budget. Middle and tail pages
        // still have reserved space, so a verbose first page cannot consume all
        // memory before representative pages are read.
        let weights = indices.map { $0 < 3 ? 2 : 1 }
        let unit = max(1, context.maxChars / weights.reduce(0, +))
        var parts: [String] = []
        var used = 0
        var truncated = indices.count < pageCount
        for (index, weight) in zip(indices, weights) {
            if used >= context.maxChars { truncated = true; break }
            let pageText = document.page(at: index)?.string ?? ""
            let allowance = min(unit * weight, context.maxChars - used)
            let selected = Py.prefix(pageText, allowance)
            if !selected.isEmpty {
                parts.append(selected)
                used += Py.count(selected)
            }
            truncated = truncated || Py.count(selected) < Py.count(pageText)
        }
        let combined = parts.joined(separator: "\n")
        truncated = truncated || Py.count(combined) > context.maxChars
        return finalizeText(Py.prefix(combined, context.maxChars), truncated: truncated)
    }
}

public struct ExtractorError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
