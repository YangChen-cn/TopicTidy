import Foundation
import Translation

struct Pair: Codable {
    let source: String
    let target: String
}

struct Request: Codable {
    let operation: String
    let pairs: [Pair]?
    let source: String?
    let target: String?
    let texts: [String]?
}

struct PairResult: Codable {
    let source: String
    let target: String
    let status: String
}

struct Response: Codable {
    var statuses: [PairResult]? = nil
    var translations: [String]? = nil
    var error: String? = nil
}

func statusName(_ status: LanguageAvailability.Status) -> String {
    switch status {
    case .installed: return "installed"
    case .supported: return "supported"
    case .unsupported: return "unsupported"
    @unknown default: return "unsupported"
    }
}

func language(_ identifier: String) -> Locale.Language {
    Locale.Language(identifier: identifier)
}

@main
struct TranslationHelper {
    static func main() async {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let request = try JSONDecoder().decode(Request.self, from: input)
            let response: Response
            switch request.operation {
            case "status":
                let availability = LanguageAvailability()
                var results: [PairResult] = []
                for pair in request.pairs ?? [] {
                    let value = await availability.status(
                        from: language(pair.source), to: language(pair.target)
                    )
                    results.append(PairResult(
                        source: pair.source, target: pair.target, status: statusName(value)
                    ))
                }
                response = Response(statuses: results)
            case "translate":
                guard let sourceID = request.source,
                      let targetID = request.target,
                      let texts = request.texts else {
                    response = Response(error: "missing translation parameters")
                    break
                }
                let source = language(sourceID)
                let target = language(targetID)
                let value = await LanguageAvailability().status(from: source, to: target)
                guard value == .installed else {
                    response = Response(error: "language pair is \(statusName(value))")
                    break
                }
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    // This initializer is restricted to already-installed assets and
                    // therefore cannot display or initiate a download prompt.
                    let session = TranslationSession(installedSource: source, target: target)
                    var translated: [String] = []
                    for text in texts {
                        translated.append(try await session.translate(text).targetText)
                    }
                    response = Response(translations: translated)
                } else {
                    response = Response(error: "command-line installed-only translation requires macOS 26 or newer")
                }
                #else
                response = Response(error: "command-line installed-only translation requires macOS 26 SDK or newer")
                #endif
            default:
                response = Response(error: "unknown operation")
            }
            FileHandle.standardOutput.write(try JSONEncoder().encode(response))
        } catch {
            let response = Response(error: String(describing: error))
            if let data = try? JSONEncoder().encode(response) {
                FileHandle.standardOutput.write(data)
            } else {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }
}
