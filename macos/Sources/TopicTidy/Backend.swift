import Foundation

actor Backend {
    func request(_ data: Data) throws -> Response {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorFile)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: errorFile) }
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let runtime = resources.appendingPathComponent("python")
        let python = runtime.appendingPathComponent("bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "应用运行环境缺失，请重新安装 TopicTidy。"])
        }
        process.executableURL = python
        process.arguments = ["-I", "-B", "-m", "downloads_organizer.gui_bridge"]
        process.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PYTHONHOME")
        environment.removeValue(forKey: "PYTHONPATH")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TOPICTIDY_HELPERS"] = resources.appendingPathComponent("helpers").path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? "本地服务意外退出"
            throw CocoaError(.executableRuntimeMismatch, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(Response.self, from: result)
    }
}
