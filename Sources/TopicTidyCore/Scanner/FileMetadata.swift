import CoreServices
import Foundation

/// Raw `stat(2)` fields the index stores, in a Sendable container.
public struct FileStat: Sendable {
    public var size: Int
    public var modifiedAt: Double
    public var createdAt: Double
    public var device: Int
    public var inode: Int
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64

    public init?(path: String) {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return nil }
        self.size = Int(info.st_size)
        self.modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        self.modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        self.modifiedAt = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) * 1e-9
        self.createdAt = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) * 1e-9
        self.device = Int(info.st_dev)
        self.inode = Int(info.st_ino)
    }
}

public enum FileSystem {
    public static func isSymlink(_ path: String) -> Bool {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    public static func isRegularFile(_ path: String) -> Bool {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    public static func isDirectory(_ path: String) -> Bool {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    public static func exists(_ path: String) -> Bool {
        var info = Darwin.stat()
        return stat(path, &info) == 0
    }

    public static func device(_ path: String) -> Int? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return nil }
        return Int(info.st_dev)
    }
}

/// macOS provenance metadata, equivalent to the `xattr`/`mdls` fallback pair.
public enum SourceMetadata {
    public static func sourceURLs(_ path: URL) -> [String] {
        if let values = whereFromsViaExtendedAttribute(path.path) { return values }
        return whereFromsViaSpotlight(path.path)
    }

    private static let attributeName = "com.apple.metadata:kMDItemWhereFroms"

    static func whereFromsViaExtendedAttribute(_ path: String) -> [String]? {
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        let data = Data(buffer[0..<read])
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let list = plist as? [Any] else { return nil }
        return list.map { String(describing: $0) }.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }

    /// Spotlight fallback for files whose extended attribute is missing.
    ///
    /// This reads the same `kMDItemWhereFroms` value `mdls` would print, but
    /// through the native API: spawning a helper cost ~66 ms per file during
    /// scans and is unnecessary here.
    static func whereFromsViaSpotlight(_ path: String) -> [String] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL),
              let attribute = MDItemCopyAttribute(item, kMDItemWhereFroms) else {
            return []
        }
        let values = (attribute as? [Any]) ?? [attribute]
        return values.map { String(describing: $0) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }
}

enum ProcessRunner {
    /// Run a helper for its exit status only, discarding its output.
    static func runStatus(_ executable: String, _ arguments: [String]) -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
