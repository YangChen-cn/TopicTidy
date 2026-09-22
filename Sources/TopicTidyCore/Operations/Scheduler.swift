import Foundation

public struct ScheduleStatus: Sendable {
    public var state: String
    public var configured: Bool
    public var loaded: Bool
    public var time: String?
    public var plistPath: String
    public var command: [String]

    /// Compatibility alias: enabled means launchd has actually loaded it.
    public var enabled: Bool { loaded }

    public var asDictionary: [String: Any] {
        [
            "state": state,
            "configured": configured,
            "loaded": loaded,
            "time": time ?? NSNull(),
            "plist_path": plistPath,
            "command": command,
            "enabled": enabled,
        ]
    }
}

/// macOS launchd adapter shared by the CLI and the GUI.
public final class LaunchAgentScheduler {
    public static let label = "com.topictidy.daily"

    private let settings: Settings
    public let plistPath: URL

    public init(_ settings: Settings, plistPath: URL? = nil) {
        self.settings = settings
        self.plistPath = plistPath ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentScheduler.label).plist")
    }

    /// The native `tt` binary that runs the daily task.
    public var command: [String] {
        [Self.executablePath(), "auto", "run"]
    }

    /// Prefer an explicitly installed CLI, then the copy inside the app bundle,
    /// and finally the running executable itself.
    public static func executablePath() -> String {
        if let configured = ProcessInfo.processInfo.environment["TOPICTIDY_EXECUTABLE"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        if Bundle.main.bundleURL.pathExtension == "app",
           let resources = Bundle.main.resourceURL {
            let bundled = PyPath.join(resources, "tt").path
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        if let argument = CommandLine.arguments.first, argument.contains("/") {
            let resolved = Paths.resolve(Paths.expand(argument)).path
            if FileManager.default.isExecutableFile(atPath: resolved) { return resolved }
        }
        return Paths.resolve(Paths.expand(CommandLine.arguments.first ?? "tt")).path
    }

    public static func parseDailyTime(_ value: String) throws -> (Int, Int) {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            throw OrganizerError("时间必须使用 HH:MM 格式，例如 09:00")
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw OrganizerError("时间必须使用 00:00 到 23:59")
        }
        return (hour, minute)
    }

    public func status() -> ScheduleStatus {
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return ScheduleStatus(state: "not_configured", configured: false, loaded: false,
                                  time: nil, plistPath: plistPath.path, command: command)
        }
        var time: String?
        var command = self.command
        if let data = try? Data(contentsOf: plistPath),
           let payload = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            if let interval = payload["StartCalendarInterval"] as? [String: Any],
               let hour = interval["Hour"] as? Int, let minute = interval["Minute"] as? Int {
                time = String(format: "%02d:%02d", hour, minute)
            }
            if let arguments = payload["ProgramArguments"] as? [String] {
                command = arguments
            }
        }
        let loaded = Self.isLoaded()
        return ScheduleStatus(state: loaded ? "loaded" : "configured_not_loaded", configured: true,
                              loaded: loaded, time: time, plistPath: plistPath.path, command: command)
    }

    static func isLoaded() -> Bool {
        let domain = "gui/\(getuid())"
        let result = ProcessRunner.runStatus("/bin/launchctl", ["print", "\(domain)/\(label)"])
        return result == 0
    }

    @discardableResult
    public func enable(at time: String) throws -> ScheduleStatus {
        let (hour, minute) = try LaunchAgentScheduler.parseDailyTime(time)
        let logs = PyPath.join(settings.dataDir, "logs")
        try? FileManager.default.createDirectory(atPath: logs.path, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: plistPath.deletingLastPathComponent().path,
                                                 withIntermediateDirectories: true)
        var environment = [
            "DOWNLOADS_ORGANIZER_DOWNLOADS": settings.downloads.path,
            "DOWNLOADS_ORGANIZER_HOME": settings.dataDir.path,
        ]
        if let destination = settings.organizedRoot?.path {
            environment["DOWNLOADS_ORGANIZER_DESTINATION"] = destination
        }
        let payload: [String: Any] = [
            "Label": LaunchAgentScheduler.label,
            "ProgramArguments": command,
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "ProcessType": "Background",
            "StandardOutPath": PyPath.join(logs, "daily.log").path,
            "StandardErrorPath": PyPath.join(logs, "daily-error.log").path,
            "EnvironmentVariables": environment,
        ]
        let previous = try? Data(contentsOf: plistPath)
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let temporary = plistPath.appendingPathExtension("tmp")
        try data.write(to: temporary)
        _ = try? FileManager.default.replaceItemAt(plistPath, withItemAt: temporary)

        let domain = "gui/\(getuid())"
        _ = ProcessRunner.runStatus("/bin/launchctl", ["bootout", domain, plistPath.path])
        let loaded = ProcessRunner.runStatus("/bin/launchctl", ["bootstrap", domain, plistPath.path])
        if loaded != 0 {
            if let previous {
                try? previous.write(to: plistPath)
                _ = ProcessRunner.runStatus("/bin/launchctl", ["bootstrap", domain, plistPath.path])
            } else {
                try? FileManager.default.removeItem(at: plistPath)
            }
            throw OrganizerError("launchctl bootstrap 失败")
        }
        return status()
    }

    @discardableResult
    public func disable() -> ScheduleStatus {
        let domain = "gui/\(getuid())"
        if FileManager.default.fileExists(atPath: plistPath.path) {
            _ = ProcessRunner.runStatus("/bin/launchctl", ["bootout", domain, plistPath.path])
            try? FileManager.default.removeItem(at: plistPath)
        }
        return status()
    }
}
