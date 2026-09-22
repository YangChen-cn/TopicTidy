import Foundation
import NaturalLanguage

public struct EncodedVector: Sendable, Equatable {
    public var vector: [Double]?
    public var space: String?

    public init(vector: [Double]?, space: String?) {
        self.vector = vector
        self.space = space
    }
}

public protocol SemanticEncoder: AnyObject {
    var version: String { get }
    func encode(_ texts: [String]) throws -> [EncodedVector]
    func encodeInLanguage(_ texts: [String], language: String) throws -> [EncodedVector]
}

public struct SemanticEncodingError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Offline sentence embeddings backed by macOS NaturalLanguage.
///
/// This replaces the previous Swift helper subprocess: the same
/// `NLEmbedding.sentenceEmbedding` calls now run in-process.
public final class NativeMacOSEncoder: SemanticEncoder {
    public init() {}

    public var version: String {
        "apple-nlembedding:\(SystemVersion.release):native"
    }

    /// Chunk the text and keep at most `limit` evenly spaced samples.
    static func sampledChunks(_ text: String, limit: Int = 16, chunkSize: Int = 1200) -> [String] {
        let value = text as NSString
        guard value.length > 0 else { return [] }
        var chunks: [String] = []
        var offset = 0
        while offset < value.length {
            let length = min(chunkSize, value.length - offset)
            chunks.append(value.substring(with: NSRange(location: offset, length: length)))
            offset += length
        }
        guard chunks.count > limit else { return chunks }
        return (0..<limit).map { index in
            let position = Int((Double(index) * Double(chunks.count - 1) / Double(limit - 1)).rounded())
            return chunks[position]
        }
    }

    static func normalizedAverage(_ vectors: [[Double]]) -> [Double]? {
        guard let first = vectors.first else { return nil }
        var result = Array(repeating: 0.0, count: first.count)
        for vector in vectors where vector.count == result.count {
            for index in result.indices { result[index] += vector[index] }
        }
        let divisor = Double(vectors.count)
        result = result.map { $0 / divisor }
        let norm = sqrt(result.reduce(0.0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return result.map { $0 / norm }
    }

    func encode(_ text: String, requestedLanguage: String?) throws -> EncodedVector {
        if let requestedLanguage {
            let language = NLLanguage(rawValue: requestedLanguage)
            guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
                return EncodedVector(vector: nil, space: requestedLanguage)
            }
            let vectors = Self.sampledChunks(text).compactMap { embedding.vector(for: $0) }
            return EncodedVector(vector: Self.normalizedAverage(vectors), space: language.rawValue)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(Py.prefix(text, 8000))
        let detected = recognizer.dominantLanguage
        let language = detected ?? .english
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            return EncodedVector(vector: nil, space: detected?.rawValue)
        }
        let vectors = Self.sampledChunks(text).compactMap { embedding.vector(for: $0) }
        return EncodedVector(vector: Self.normalizedAverage(vectors), space: language.rawValue)
    }

    public func encode(_ texts: [String]) throws -> [EncodedVector] {
        try texts.map { try encode($0, requestedLanguage: nil) }
    }

    /// Encode with one explicit NLEmbedding language space.
    public func encodeInLanguage(_ texts: [String], language: String) throws -> [EncodedVector] {
        try texts.map { try encode($0, requestedLanguage: language) }
    }
}

public enum SemanticStatus {
    /// Language availability probe. Never downloads assets.
    public static func native(
        languages: [String] = ["en", "zh-Hans"],
        inspectLanguages: Bool = false
    ) -> [String: Any] {
        var result: [String: Any] = [
            "backend": "apple-nlembedding",
            "available": true,
            "prepared": true,
            "download_required": false,
        ]
        if inspectLanguages {
            let encoder = NativeMacOSEncoder()
            let samples = ["en": "renewable energy systems", "zh-Hans": "可再生能源系统"]
            var states: [String: String] = [:]
            for language in languages {
                let encoded = (try? encoder.encodeInLanguage([samples[language] ?? language], language: language))?.first
                states[language] = (encoded?.vector != nil) ? "available" : "unavailable"
            }
            result["languages"] = states
        }
        return result
    }
}
