import Foundation

public struct OrganizerPreferences: Sendable, Equatable {
    public var destination: URL
    public var autoConfirmEnabled: Bool
    public var autoConfirmThreshold: Double

    public var asDictionary: [String: Any] {
        [
            "destination": destination.path,
            "auto_confirm_enabled": autoConfirmEnabled,
            "auto_confirm_threshold": autoConfirmThreshold,
        ]
    }
}

/// Persistence API shared by the CLI and the GUI.
public final class PreferenceStore {
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
        let destination = Paths.resolve(Paths.expand(
            stored[PreferenceStore.destinationKey] ?? base.organizedDir.path
        ))
        let fallbackEnabled = base.autoConfirmEnabled ? "1" : "0"
        let enabled = (stored[PreferenceStore.autoConfirmEnabledKey] ?? fallbackEnabled) == "1"
        var threshold = Double(stored[PreferenceStore.autoConfirmThresholdKey] ?? "")
            ?? base.autoConfirmThreshold
        threshold = min(1.0, max(0.85, threshold))
        return OrganizerPreferences(destination: destination, autoConfirmEnabled: enabled,
                                    autoConfirmThreshold: threshold)
    }

    public func resolvedSettings() -> Settings {
        let preferences = get()
        return base.with(
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
        if resolved.path == Paths.resolve(base.downloads).path {
            throw OrganizerError("整理根目录不能直接等于 Downloads；请指定一个子目录或其他目录")
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
        guard let parentDevice = FileSystem.device(existingParent.path),
              let downloadsDevice = FileSystem.device(base.downloads.path) else {
            throw OrganizerError("无法读取磁盘信息")
        }
        if parentDevice != downloadsDevice {
            throw OrganizerError("当前版本仅支持与 Downloads 位于同一磁盘的整理目录")
        }
        try set(PreferenceStore.destinationKey, resolved.path)
        return get()
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
