import Foundation

/// Single-writer guard shared by the CLI, the GUI and the daily task.
public enum AppLock {
    public static func withLock<T>(_ dataDir: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: dataDir.path, withIntermediateDirectories: true)
        let lockPath = PyPath.join(dataDir, "organizer.lock").path
        let descriptor = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw OrganizerError("无法打开应用锁：\(lockPath)")
        }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            throw OrganizerError("另一个 Downloads Organizer 进程正在运行")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
