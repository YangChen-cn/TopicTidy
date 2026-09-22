import Foundation
import Testing

@testable import TopicTidyCore

func fixtureDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
}

/// Expectations below were captured from the Python reference implementation
/// before it was removed; see docs/MIGRATION.md.
@Test func docxExtractorMatchesReferenceOutput() throws {
    let path = fixtureDirectory().appendingPathComponent("electric6008-notes.docx")
    let registry = ExtractorRegistry.default()
    #expect(registry.cacheVersion(path) == "docx:1;text-features:2")

    let result = registry.extract(path, maxChars: 120_000)
    #expect(result.error == nil)
    #expect(result.title == "ELEC6008 Power Electronics")
    #expect(result.keywords == ["power", "electronics", "converter", "design", "inverter", "control",
                               "switching", "elec6008", "systems", "losses", "modulation", "thermal"])
    #expect(result.summary == "ELEC6008 Power Electronics Converter design and inverter control for "
        + "power electronics systems. Lecture notes on switching losses, modulation and thermal design. "
        + "Week 3 covers resonant converters and soft switching topologies. Week 1")
    #expect(result.text == """
    ELEC6008 Power Electronics
    Converter design and inverter control for power electronics systems.
    Lecture notes on switching losses, modulation and thermal design.
    Week 3 covers resonant converters and soft switching topologies.
    Week 1
    Converter basics
    Week 2
    Inverter control
    """)
    #expect(result.truncated == false)
}

@Test func pptxExtractorMatchesReferenceOutput() throws {
    let path = fixtureDirectory().appendingPathComponent("electric6008-slides.pptx")
    let registry = ExtractorRegistry.default()
    #expect(registry.cacheVersion(path) == "pptx:1;text-features:2")

    let result = registry.extract(path, maxChars: 120_000)
    #expect(result.error == nil)
    #expect(result.title == "ELEC6008 Lecture 01")
    #expect(result.keywords == ["elec6008", "power", "electronics", "converter", "design",
                               "inverter", "control", "modulation"])
    #expect(result.text == """
    ELEC6008 Lecture 01
    Power electronics converter design
    ELEC6008 Lecture 02
    Inverter control and modulation
    """)
}

@Test func pdfExtractorMatchesReferenceOutput() throws {
    let path = fixtureDirectory().appendingPathComponent("grid-storage.pdf")
    let registry = ExtractorRegistry.default()
    #expect(registry.cacheVersion(path) == "pdf:2;text-features:2")

    let result = registry.extract(path, maxChars: 120_000)
    #expect(result.error == nil)
    #expect(result.title == "Grid Storage Design")
    #expect(result.keywords == ["storage", "grid", "design", "page", "large", "scale", "battery",
                               "report", "renewable", "systems", "second", "representative"])
    #expect(result.text.contains("Large scale battery storage design report"))
    #expect(result.text.contains("Third page."))
}

@Test func docxExtractorHonoursTextBudget() throws {
    let path = fixtureDirectory().appendingPathComponent("electric6008-notes.docx")
    let result = try DocxExtractor().extract(path, context: ExtractionContext(maxChars: 40))
    #expect(result.title == "ELEC6008 Power Electronics")
    #expect(Py.count(result.text) <= 40)
    #expect(result.truncated)
}

@Test func corruptPDFIsReportedAsExtractionError() throws {
    let directory = try TemporaryDirectory()
    let path = directory.url.appendingPathComponent("broken.pdf")
    try Data("not a pdf".utf8).write(to: path)

    let result = ExtractorRegistry.default().extract(path, maxChars: 1000)
    #expect(result.error != nil)
    #expect(result.text.isEmpty)
}

@Test func pdfPageSamplingReadsFrontMiddleAndTail() {
    #expect(sampledPageIndices(3) == [0, 1, 2])
    #expect(sampledPageIndices(8) == [0, 1, 2, 3, 4, 5, 6, 7])
    #expect(sampledPageIndices(100) == [0, 1, 2, 25, 50, 74, 98, 99])
}

@Test func plainTextExtractorReportsTruncation() throws {
    let directory = try TemporaryDirectory()
    let path = directory.url.appendingPathComponent("notes.md")
    try String(repeating: "a", count: 500).write(to: path, atomically: true, encoding: .utf8)

    let result = try PlainTextExtractor().extract(path, context: ExtractionContext(maxChars: 100))
    #expect(Py.count(result.text) == 100)
    #expect(result.truncated)
}

@Test func miniZipReadsStoredAndDeflatedEntries() throws {
    let path = fixtureDirectory().appendingPathComponent("electric6008-slides.pptx")
    let archive = try MiniZip(data: Data(contentsOf: path))
    #expect(archive.entry(named: "ppt/presentation.xml") != nil)
    let slide = try #require(try archive.readEntry(named: "ppt/slides/slide1.xml"))
    let text = String(decoding: slide, as: UTF8.self)
    #expect(text.contains("ELEC6008 Lecture 01"))

    let docx = try MiniZip(data: Data(contentsOf: fixtureDirectory().appendingPathComponent("electric6008-notes.docx")))
    let document = try #require(try docx.readEntry(named: "word/document.xml"))
    #expect(String(decoding: document, as: UTF8.self).contains("Converter basics"))
}

struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("topictidy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}
