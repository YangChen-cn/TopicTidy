import Compression
import Foundation

/// Minimal read-only ZIP reader for OOXML containers.
///
/// OOXML parts are stored or DEFLATE-compressed; both are supported without a
/// third-party dependency. Apple's `COMPRESSION_ZLIB` codec is raw DEFLATE,
/// which is exactly what a ZIP entry contains.
public struct MiniZip {
    public struct Entry {
        public let name: String
        public let compressionMethod: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
    }

    private let data: Data
    public let entries: [Entry]
    private let byName: [String: Entry]

    public init(data: Data) throws {
        self.data = data
        var entries: [Entry] = []
        var byName: [String: Entry] = [:]
        guard let eocd = MiniZip.endOfCentralDirectory(data) else {
            throw ExtractorError("不是有效的 ZIP/OOXML 文件")
        }
        let count = Int(MiniZip.u16(data, eocd + 10))
        let directoryOffset = Int(MiniZip.u32(data, eocd + 16))
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= data.count, MiniZip.u32(data, cursor) == 0x0201_4B50 else { break }
            let method = MiniZip.u16(data, cursor + 10)
            let compressedSize = Int(MiniZip.u32(data, cursor + 20))
            let uncompressedSize = Int(MiniZip.u32(data, cursor + 24))
            let nameLength = Int(MiniZip.u16(data, cursor + 28))
            let extraLength = Int(MiniZip.u16(data, cursor + 30))
            let commentLength = Int(MiniZip.u16(data, cursor + 32))
            let localOffset = Int(MiniZip.u32(data, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            let entry = Entry(
                name: name, compressionMethod: method, compressedSize: compressedSize,
                uncompressedSize: uncompressedSize, localHeaderOffset: localOffset
            )
            entries.append(entry)
            byName[name] = entry
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
        self.byName = byName
    }

    public func entry(named name: String) -> Entry? { byName[name] }

    public func read(_ entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, MiniZip.u32(data, header) == 0x0403_4B50 else {
            throw ExtractorError("ZIP 局部文件头无效：\(entry.name)")
        }
        let nameLength = Int(MiniZip.u16(data, header + 26))
        let extraLength = Int(MiniZip.u16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else {
            throw ExtractorError("ZIP 数据越界：\(entry.name)")
        }
        let payload = data[start..<(start + entry.compressedSize)]
        switch entry.compressionMethod {
        case 0:
            return Data(payload)
        case 8:
            return try MiniZip.inflate(Data(payload), expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ExtractorError("不支持的 ZIP 压缩方式 \(entry.compressionMethod)：\(entry.name)")
        }
    }

    public func readEntry(named name: String) throws -> Data? {
        guard let entry = byName[name] else { return nil }
        return try read(entry)
    }

    static func inflate(_ payload: Data, expectedSize: Int, name: String) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0x1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 0x1)!, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else {
            throw ExtractorError("无法初始化解压器：\(name)")
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        output.reserveCapacity(max(expectedSize, bufferSize))
        var failure: Error?
        payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = raw.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                if status == COMPRESSION_STATUS_ERROR {
                    failure = ExtractorError("DEFLATE 解压失败：\(name)")
                    return
                }
                let produced = bufferSize - stream.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
                if status == COMPRESSION_STATUS_END { return }
                if stream.src_size == 0 && produced == 0 { return }
            }
        }
        if let failure { throw failure }
        return output
    }

    static func endOfCentralDirectory(_ data: Data) -> Int? {
        let minimumSize = 22
        guard data.count >= minimumSize else { return nil }
        let maximumBackscan = min(data.count, 65_557)
        var offset = data.count - minimumSize
        let limit = data.count - maximumBackscan
        while offset >= limit {
            if u32(data, offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
