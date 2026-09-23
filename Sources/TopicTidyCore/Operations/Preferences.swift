import Foundation

public struct OrganizerPreferences: Sendable, Equatable {
    public var scanRoots: [URL]
    public var destination: URL
    public var autoConfirmEnabled: Bool
    public var autoConfirmThreshold: Double

    public var asDictionary: [String: Any] {
        [
            "scan_roots": scanRoots.map(\.path),
            "destination": destination.path,
            "auto_confirm_enabled": autoConfirmEnabled,
            "auto_confirm_threshold": autoConfirmThreshold,
        ]
    }
}

/// Persistence API shared by the CLI and the GUI.
public final class PreferenceStore {
    public static let scanRootsKey = "scan_roots"
    public static let destinationKey = "destination"
    public static let autoConfirmEnabledKey = "auto_confirm_enabled"
    public static let autoConfirmThresholdKey = "auto_confirm_threshold"

    private let db: Database
    private let base: Settings

    public init(_ db: Database, base: Settings) {
        self.db = db
        self.base = base
    }

    private func values() -> [String: String] {
        let rows = (try? db.connection.query("SELECT key,value FROM app_settings")) ?? []
        var result: [String: String] = [:]
        for row in rows { result[row["key"].string] = row["value"].string }
        return result
    }

    public func get() -> OrganizerPreferences {
        let stored = values()
        let savedRoots = stored[PreferenceStore.scanRootsKey].map(JSONValue.stringArray) ?? []
        let scanRoots = savedRoots.isEmpty ? [base.downloads] : savedRoots.map { Paths.resolve(Paths.expand($0)) }
        let destination = Paths.resolve(Paths.expand(
            stored[PreferenceStore.destinationKey] ?? base.organizedDir.path
        ))
        let fallbackEnabled = base.autoConfirmEnabled ? "1" : "0"
        let enabled = (stored[PreferenceStore.autoConfirmEnabledKey] ?? fallbackEnabled) == "1"
        var threshold = Double(stored[PreferenceStore.autoConfirmThresholdKey] ?? "")
            ?? base.autoConfirmThreshold
        threshold = min(1.0, max(0.85, threshold))
        return OrganizerPreferences(scanRoots: scanRoots, destination: destination, autoConfirmEnabled: enabled,
                                    autoConfirmThreshold: threshold)
    }

    public func resolvedSettings() -> Settings {
        let preferences = get()
        return base.with(
            scanRoots: preferences.scanRoots,
            organizedRoot: preferences.destination,
            autoConfirmEnabled: preferences.autoConfirmEnabled,
            autoConfirmThreshold: preferences.autoConfirmThreshold
        )
    }

    private func set(_ key: String, _ value: String) throws {
        try db.connection.run(
            """
            INSERT INTO app_settings(key,value,updated_at) VALUES(?,?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at
            """,
            [key, value, Date().timeIntervalSince1970]
        )
    }

    @discardableResult
    public func setDestination(_ destination: URL) throws -> OrganizerPreferences {
        let expanded = URL(fileURLWithPath: Paths.expand(destination.path))
        if FileSystem.isSymlink(expanded.path) {
            throw OrganizerError("整理根目录不能是符号链接")
        }
        let resolved = Paths.resolve(expanded)
        let roots = get().scanRoots
        if roots.contains(where: { Operations.within($0, resolved) || $0.path == resolved.path }) {
            throw OrganizerError("整理根目录不能等于或包含扫描目录")
        }
        if FileSystem.exists(resolved.path) && !FileSystem.isDirectory(resolved.path) {
            throw OrganizerError("整理根目录已存在，但不是目录")
        }
        var existingParent = resolved
        while !FileSystem.exists(existingParent.path) {
            let parent = existingParent.deletingLastPathComponent()
            if parent.path == existingParent.path { break }
            existingParent = parent
        }
        guard let parentDevice = FileSystem.device(existingParent.path) else {
            throw OrganizerError("无法读取磁盘信息")
        }
        if roots.contains(where: { FileSystem.device($0.path) != parentDevice }) {
            throw OrganizerError("当前版本仅支持与扫描目录位于同一磁盘的整理目录")
        }
        try set(PreferenceStore.destinationKey, resolved.path)
        return get()
    }

    @discardableResult
    public func setScanRoots(_ proposed: [URL]) throws -> OrganizerPreferences {
        guard !proposed.isEmpty else { throw OrganizerError("至少保留一个扫描目录") }
        let destination = get().destination
        var roots: [URL] = []
        for proposedRoot in proposed {
            let expanded = URL(fileURLWithPath: Paths.expand(proposedRoot.path))
            if FileSystem.isSymlink(expanded.path) { throw OrganizerError("扫描目录不能是符号链接：\(expanded.path)") }
            let root = Paths.resolve(expanded)
            guard FileSystem.isDirectory(root.path) else {
                throw OrganizerError("扫描目录不存在或不是文件夹：\(root.path)")
            }
            if Operations.within(root, destination) {
                throw OrganizerError("扫描目录不能位于整理目录内：\(root.path)")
            }
            if roots.contains(where: { Operations.within(root, $0) || Operations.within($0, root) }) {
                throw OrganizerError("扫描目录重复或相互包含：\(root.path)")
            }
            guard let rootDevice = FileSystem.device(root.path),
                  let destinationDevice = FileSystem.device(existingAncestor(of: destination).path),
                  rootDevice == destinationDevice else {
                throw OrganizerError("当前版本仅支持与整理目录位于同一磁盘的扫描目录")
            }
            roots.append(root)
        }
        let changed = roots.map(\.path) != get().scanRoots.map { Paths.resolve($0).path }
        try db.withTransaction { _ in
            try set(PreferenceStore.scanRootsKey, JSONValue.dumps(roots.map(\.path)))
            // Ongoing consent to move files from one folder does not silently
            // extend to a newly added folder.
            if changed { try set(PreferenceStore.autoConfirmEnabledKey, "0") }
        }
        return get()
    }

    private func existingAncestor(of path: URL) -> URL {
        var current = path
        while !FileSystem.exists(current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return current
    }

    @discardableResult
    public func setAutoConfirm(_ enabled: Bool, threshold: Double? = nil) throws -> OrganizerPreferences {
        if let threshold, !(0.85 <= threshold && threshold <= 1.0) {
            throw OrganizerError("自动确认阈值必须在 0.85 到 1.0 之间")
        }
        try set(PreferenceStore.autoConfirmEnabledKey, enabled ? "1" : "0")
        if let threshold {
            try set(PreferenceStore.autoConfirmThresholdKey, String(format: "%.6f", threshold))
        }
        return get()
    }
}
