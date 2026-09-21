import Foundation
import NaturalLanguage

struct Request: Codable {
    let texts: [String]
}

struct Response: Codable {
    let vectors: [[Double]?]
    let languages: [String?]
}

func sampledChunks(_ text: String, limit: Int = 16, chunkSize: Int = 1200) -> [String] {
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
        let position = Int(round(Double(index) * Double(chunks.count - 1) / Double(limit - 1)))
        return chunks[position]
    }
}

func normalizedAverage(_ vectors: [[Double]]) -> [Double]? {
    guard let first = vectors.first else { return nil }
    var result = Array(repeating: 0.0, count: first.count)
    for vector in vectors where vector.count == result.count {
        for index in result.indices {
            result[index] += vector[index]
        }
    }
    let divisor = Double(vectors.count)
    result = result.map { $0 / divisor }
    let norm = sqrt(result.reduce(0.0) { $0 + $1 * $1 })
    guard norm > 0 else { return nil }
    return result.map { $0 / norm }
}

func encode(_ text: String) -> ([Double]?, String?) {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(String(text.prefix(8000)))
    let detected = recognizer.dominantLanguage
    let language = detected ?? .english
    guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
        return (nil, detected?.rawValue)
    }
    let vectors = sampledChunks(text).compactMap { embedding.vector(for: $0) }
    return (normalizedAverage(vectors), language.rawValue)
}

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let request = try JSONDecoder().decode(Request.self, from: input)
    let encoded = request.texts.map(encode)
    let response = Response(vectors: encoded.map(\.0), languages: encoded.map(\.1))
    FileHandle.standardOutput.write(try JSONEncoder().encode(response))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

