import ArgumentParser
import Foundation
import TopicTidyCore

/// Shared context: base settings, the resolved preferences, and an open database.
struct Context {
    let base: Settings
    let settings: Settings
    let db: Database
    let recovered: Int

    static func open() throws -> Context {
        let base = Settings.load()
        let db = try Database(path: base.database)
        let settings = PreferenceStore(db, base: base).resolvedSettings()
        let recovered = try db.recoverInterrupted()
        return Context(base: base, settings: settings, db: db, recovered: recovered)
    }

    func close() { db.close() }
}

func output(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func prompt(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func outputJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value,
                                            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]))
        ?? Data()
    output(String(data: data, encoding: .utf8) ?? "{}")
}

@main
struct TT: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tt",
        abstract: "本地、可解释、可撤销的 macOS Downloads 整理器",
        version: AppInfo.version,
        subcommands: [
            Scan.self, Propose.self, Review.self, Apply.self, History.self, Undo.self,
            ConfigCommand.self, BenchmarkCommand.self, Semantic.self, Schedule.self,
            Auto.self, Watch.self,
        ]
    )
}

// MARK: - scan

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "扫描已配置文件夹的顶层并更新本地索引。")

    func run() throws {
        let context = try Context.open()
        defer { context.close() }
        let stats = try AppLock.withLock(context.settings.dataDir) {
            try Scanner.scan(context.db, context.settings)
        }
        output("扫描完成：新增/更新 \(stats.scanned)，未变化 \(stats.unchanged)，"
            + "跳过 \(stats.skipped)，提取错误 \(stats.errors)")
    }
}

// MARK: - propose

struct Propose: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "基于当前索引生成并保存整理建议。")

    @Flag(name: .long, help: "输出机器可读 JSON")
    var json = false

    @Flag(name: .customLong("no-semantic"), help: "跳过 macOS 原生语义向量")
    var noSemantic = false

    func run() throws {
        let context = try Context.open()
        defer { context.close() }
        let result = try AppLock.withLock(context.settings.dataDir) {
            try Workflow.createProposal(context.db, context.settings, useSemantic: !noSemantic)
        }
        if json {
            outputJSON([
                "plan_id": result.planID,
                "groups": result.groups.map { $0.asDictionary(destination: context.settings.organizedDir) },
                "unclassified": result.unclassified.map { $0.path.path },
                "unclassified_reasons": Dictionary(uniqueKeysWithValues: result.unclassified.map {
                    ($0.path.path, result.unclassifiedReasons[$0.id] ?? "尚无足够证据")
                }),
                "semantic_backend_used": result.encoderVersion as Any,
                "semantic_error": result.semanticError as Any,
                "translation_backend_used": result.translationVersion as Any,
                "translation_warnings": result.translationWarnings,
            ])
        } else {
            try renderPlan(context.db, context.settings, planID: result.planID)
            if let semanticError = result.semanticError {
                output("\n原生语义不可用，已继续使用其他特征：\(semanticError)")
            } else if result.encoderVersion == nil {
                output("\n已按要求跳过原生语义特征。")
            }
            for message in result.translationWarnings {
                output("\n跨语言语义已降级：\(message)")
            }
            output("\n审阅：tt review \(result.planID)")
        }
    }
}

func renderPlan(_ db: Database, _ settings: Settings, planID: Int) throws {
    let rows = try Operations.planRows(db, planID)
    var grouped: [String: [Row]] = [:]
    var order: [String] = []
    for row in rows {
        let name = row["group_name"].optionalString ?? "Unclassified"
        if grouped[name] == nil { order.append(name) }
        grouped[name, default: []].append(row)
    }
    output("\nProposed organization (plan \(planID)):")
    for group in order {
        let members = grouped[group]!
        let confidence = members.map { $0["confidence"].double }.max() ?? 0
        let label = group == "Unclassified"
            ? "[\(group)]"
            : "[\(group)] confidence=\(format2(confidence)) (启发式)"
        output("\n\(label)")
        for row in members {
            let excluded = row["excluded"].int != 0 ? " (excluded)" : ""
            let reason = row["member_reason"].string
            output("  #\(row["id"].int) \(row["name"].string)\(excluded)\(reason.isEmpty ? "" : " · \(reason)")")
        }
        let evidence = JSONValue.dictionaryArray(members[0]["evidence"].string)
        if !evidence.isEmpty {
            for item in evidence {
                let strength = item["strength"] as? String ?? "none"
                output("  \(strength.uppercased()) \(item["detail"] as? String ?? "")")
            }
        } else {
            let reasons = JSONValue.stringArray(members[0]["reasons"].string)
            if !reasons.isEmpty { output("  依据：" + reasons.joined(separator: "；")) }
        }
    }
}

// MARK: - review

struct Review: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "在终端中修订分组方案；不会移动文件。")

    @Argument(help: "方案编号")
    var planID: Int

    static let help = """
    命令：
      list
      rename <旧主题> <新主题>
      move <成员编号> <主题>
      split <成员编号> <新主题>
      merge <源主题...> <目标主题>
      exclude <成员编号>
      folder <主题> <整理根目录内已有目录>
      done
    """

    func run() throws {
        let context = try Context.open()
        defer { context.close() }
        let exists = try context.db.connection.query("SELECT 1 FROM plans WHERE id=?", [planID]).first != nil
        guard exists else { throw ValidationError("方案 \(planID) 不存在") }
        try renderPlan(context.db, context.settings, planID: planID)
        output(Review.help)
        while true {
            prompt("review> ")
            guard let line = readLine() else { break }
            let parts = splitArguments(line)
            if parts.isEmpty { continue }
            if ["done", "quit", "exit"].contains(parts[0]) {
                try context.db.connection.run("UPDATE plans SET status='reviewed' WHERE id=?", [planID])
                output("审阅已保存。下一步执行：tt apply \(planID)")
                break
            }
            if ["help", "?"].contains(parts[0]) {
                output(Review.help)
                continue
            }
            if parts[0] == "list" {
                try renderPlan(context.db, context.settings, planID: planID)
                continue
            }
            do {
                let message = try AppLock.withLock(context.settings.dataDir) {
                    let root = try Operations.planDestinationRoot(context.db, context.settings, planID)
                    return try Operations.editPlan(context.db, planID, command: parts[0],
                                                   args: Array(parts.dropFirst()), organizedDir: root)
                }
                output(message)
            } catch {
                output("\(error)")
            }
        }
    }
}

/// Minimal shell-like splitting matching `shlex.split` for the review prompt.
func splitArguments(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var started = false
    for character in line {
        if let active = quote {
            if character == active {
                quote = nil
            } else {
                current.append(character)
            }
            continue
        }
        if character == "\"" || character == "'" {
            quote = character
            started = true
            continue
        }
        if character == " " || character == "\t" {
            if started || !current.isEmpty {
                result.append(current)
                current = ""
                started = false
            }
            continue
        }
        current.append(character)
    }
    if started || !current.isEmpty { result.append(current) }
    return result
}

// MARK: - apply

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "确认并执行已保存方案中的移动。")

    @Argument(help: "方案编号")
    var planID: Int

    @Flag(name: [.short, .long], help: "跳过确认")
    var yes = false

    func run() throws {
        let context = try Context.open()
        defer { context.close() }
        let moves = try Operations.previewMoves(context.db, context.settings, planID)
        if moves.isEmpty {
            output("方案中没有需要移动的文件。")
            return
        }
        output("源文件\t目标\t状态")
        for move in moves {
            output("\(move.source.path)\t\(move.destination.path)\t\(move.stale ? "已变化" : "就绪")")
        }
        if !yes {
            prompt("执行以上移动？ [y/N] ")
            let answer = readLine()?.lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                output("已取消。")
                return
            }
        }
        let (batchID, results) = try AppLock.withLock(context.settings.dataDir) {
            try Operations.applyPlan(context.db, context.settings, planID)
        }
        let moved = results.filter { $0.status == "moved" }.count
        output("批次 \(batchID)：已移动 \(moved)/\(results.count) 个文件。")
        for result in results where !result.error.isEmpty {
            output("跳过 \(result.source)：\(result.error)")
        }
    }
}

// MARK: - history

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "显示整理与撤销历史。")

    @Option(help: "最多显示条数")
    var limit = 30

    func run() throws {
        let context = try Context.open()
        defer { context.close() }
        let rows = try context.db.connection.query(
            "SELECT * FROM operation_batches ORDER BY created_at DESC LIMIT ?", [limit]
        )
        output("批次\t类型\t状态\t方案\t时间")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for row in rows {
            let time = formatter.string(from: Date(timeIntervalSince1970: row["created_at"].double))
            let plan = row["plan_id"].isNull ? "" : String(row["plan_id"].int)
            output("\(row["id"].int)\t\(row["kind"].string)\t\(row["status"].string)\t\(plan)\t\(time)")
        }
    }
}

// MARK: - undo

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "验证文件身份后撤销一个整理批次。")

    @Argument(help: "批次编号")
    var batchID: Int

    func run() throws {
        let context = try Context.open()
        defer { context.close() }
        let (undoID, results) = try AppLock.withLock(context.settings.dataDir) {
            try Operations.undoBatch(context.db, context.settings, batchID)
        }
        let done = results.filter { $0.status == "undone" }.count
        output("撤销批次 \(undoID)：已恢复 \(done)/\(results.count) 个文件。")
        for result in results where !result.error.isEmpty {
            output("跳过 \(result.source)：\(result.error)")
        }
    }
}

// MARK: - config

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "管理扫描目录、整理目录和自动确认设置",
        subcommands: [ConfigShow.self, ConfigSources.self, ConfigDestination.self, ConfigAutoConfirm.self]
    )

    struct ConfigShow: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "显示当前应用设置。")

        @Flag(name: .long) var json = false

        func run() throws {
            let base = Settings.load()
            let db = try Database(path: base.database)
            defer { db.close() }
            let payload = PreferenceStore(db, base: base).get().asDictionary
            if json {
                outputJSON(payload)
            } else {
                output("扫描目录：")
                for root in (payload["scan_roots"] as? [String] ?? []) { output("  \(root)") }
                output("整理目录：\(payload["destination"] as? String ?? "")")
                let enabled = (payload["auto_confirm_enabled"] as? Bool) ?? false
                output("高置信度自动确认：\(enabled ? "已启用" : "已停用")")
                let threshold = (payload["auto_confirm_threshold"] as? Double) ?? 0
                output(String(format: "自动确认阈值：%.2f（启发式）", threshold))
            }
        }
    }

    struct ConfigSources: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sources", abstract: "管理要扫描的文件夹；默认只有 Downloads。",
            subcommands: [Set.self, Add.self, Remove.self]
        )

        struct Set: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "替换全部扫描文件夹。")
            @Argument(help: "一个或多个文件夹") var paths: [String]
            func run() throws { try ConfigSources.change(.set, paths) }
        }
        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "添加扫描文件夹。")
            @Argument(help: "一个或多个文件夹") var paths: [String]
            func run() throws { try ConfigSources.change(.add, paths) }
        }
        struct Remove: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "移除扫描文件夹。")
            @Argument(help: "一个或多个文件夹") var paths: [String]
            func run() throws { try ConfigSources.change(.remove, paths) }
        }

        enum Change { case set, add, remove }
        static func change(_ operation: Change, _ paths: [String]) throws {
            guard !paths.isEmpty else { throw ValidationError("请指定至少一个文件夹") }
            let base = Settings.load()
            do {
                let saved = try AppLock.withLock(base.dataDir) {
                    let db = try Database(path: base.database)
                    defer { db.close() }
                    let store = PreferenceStore(db, base: base)
                    let current = store.get().scanRoots
                    let requested = paths.map { Paths.resolve(Paths.expand($0)) }
                    let next: [URL]
                    switch operation {
                    case .set: next = requested
                    case .add: next = current + requested
                    case .remove:
                        let removed = Swift.Set(requested.map(\.path))
                        next = current.filter { !removed.contains(Paths.resolve($0).path) }
                        if next.count == current.count { throw ValidationError("没有匹配的已配置扫描目录") }
                    }
                    return try store.setScanRoots(next)
                }
                output("扫描目录已更新：")
                for root in saved.scanRoots { output("  \(root.path)") }
                output("扫描目录有变化时，自动整理会关闭；如需使用请重新启用。")
            } catch { throw ValidationError("\(error)") }
        }
    }

    struct ConfigDestination: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "destination", abstract: "设置整理后的根目录；新方案会固化该路径。"
        )

        @Argument(help: "目录路径") var path: String

        func run() throws {
            let base = Settings.load()
            let db = try Database(path: base.database)
            defer { db.close() }
            do {
                let preferences = try PreferenceStore(db, base: base)
                    .setDestination(URL(fileURLWithPath: Paths.expand(path)))
                output("整理目录已设置为：\(preferences.destination.path)")
                output("已有方案仍使用其生成时保存的目录。")
            } catch {
                throw ValidationError("\(error)")
            }
        }
    }

    struct ConfigAutoConfirm: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "auto-confirm", abstract: "配置每日任务是否自动移动高置信度、无冲突的完整分组。"
        )

        @Flag(name: .customLong("enable"), help: "启用自动确认")
        var enable = false

        @Flag(name: .customLong("disable"), help: "停用自动确认")
        var disable = false

        @Option(help: "启发式置信度阈值（0.85–1.0）") var threshold: Double?

        func run() throws {
            if let threshold, !(0.85...1.0).contains(threshold) {
                throw ValidationError("自动确认阈值必须在 0.85 到 1.0 之间")
            }
            let base = Settings.load()
            let db = try Database(path: base.database)
            defer { db.close() }
            let enabled = enable ? true : !disable
            do {
                let preferences = try PreferenceStore(db, base: base)
                    .setAutoConfirm(enabled, threshold: threshold)
                output("高置信度自动确认已\(preferences.autoConfirmEnabled ? "启用" : "停用")；"
                    + String(format: "阈值 %.2f（启发式）。", preferences.autoConfirmThreshold))
                if preferences.autoConfirmEnabled {
                    output("低于阈值、存在冲突或未分类的文件不会移动。")
                }
            } catch {
                throw ValidationError("\(error)")
            }
        }
    }
}

// MARK: - benchmark

struct BenchmarkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark", abstract: "对标注 fixture 比较 expected clusters 与 predicted clusters。"
    )

    @Argument(help: "fixture JSON；省略时使用内置核心数据集") var fixture: String?
    @Flag(name: .long, help: "输出机器可读 JSON") var json = false
    @Option(name: .customLong("min-f1"), help: "低于阈值时返回非零退出码") var minF1 = 1.0
    @Option(name: .long, help: "legacy、expansion-only、multiview-only 或 upgraded") var variant = "upgraded"

    func run() throws {
        guard let selected = Benchmark.Variant(rawValue: variant) else {
            throw ValidationError("未知 benchmark variant：\(variant)")
        }
        let result = try Benchmark.run(fixturePath: fixture, variant: selected)
        if json {
            outputJSON(result)
        } else {
            output("Fixture: \(result["fixture"] as? String ?? "")")
            output("\nExpected clusters")
            for (name, members) in (result["expected_clusters"] as? [String: [String]] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output("  \(name): \(members.joined(separator: ", "))")
            }
            output("\nPredicted clusters")
            for (name, members) in (result["predicted_clusters"] as? [String: [String]] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output("  \(name): \(members.joined(separator: ", "))")
            }
            let precision = result["pairwise_precision"] as? Double ?? 0
            let recall = result["pairwise_recall"] as? Double ?? 0
            let f1 = result["pairwise_f1"] as? Double ?? 0
            output(String(format: "\nPairwise precision=%.4f recall=%.4f F1=%.4f", precision, recall, f1))
            output("Exact cluster match: \(result["exact_cluster_match"] as? Bool ?? false)")
            output("Unclassified match: \(result["unclassified_match"] as? Bool ?? false)")
        }
        if (result["pairwise_f1"] as? Double ?? 0) < minF1 || (result["unclassified_match"] as? Bool) != true {
            throw ExitCode.failure
        }
    }
}

// MARK: - semantic

struct Semantic: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "管理零下载的 macOS 原生语义 backend",
        subcommands: [SemanticStatusCommand.self, SemanticPrepare.self]
    )

    struct SemanticStatusCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "检查系统原生语义能力；不会下载任何内容。")

        func run() throws {
            let embedding = SemanticStatus.native(inspectLanguages: true)
            let translation = TranslationStatus.status()
            output("Apple embedding:")
            for (language, state) in (embedding["languages"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output("  \(language): \(state)")
            }
            if let error = embedding["error"] as? String { output("  \(error)") }
            output("\nCross-language translation:")
            let labels = ["installed": "installed", "supported": "not installed", "unsupported": "unavailable"]
            for (pair, state) in (translation["pairs"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output("  \(pair): \(labels[state] ?? state)")
            }
            if let error = translation["error"] as? String { output("  \(error)") }
            output("\n只检查本地资产；未请求或下载语言包。")
        }
    }

    struct SemanticPrepare: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "prepare", abstract: "检查系统模型；不访问网络。")

        func run() throws {
            let settings = Settings.load()
            try AppLock.withLock(settings.dataDir) {
                let encoder = NativeMacOSEncoder()
                let vectors = try encoder.encodeInLanguage(
                    ["renewable energy systems", "power grid control"], language: "en"
                )
                output("原生语义 backend 已就绪：\(encoder.version)")
                output("系统向量维度：\(vectors.first?.vector?.count ?? 0)")
            }
            output("未下载模型或 Python ML 框架。")
        }
    }
}

// MARK: - schedule

struct Schedule: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "管理 macOS 每日自动扫描",
        subcommands: [ScheduleStatusCommand.self, ScheduleEnable.self, ScheduleDisable.self]
    )

    struct ScheduleStatusCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "显示每日扫描 LaunchAgent 状态。")

        @Flag(name: .long) var json = false

        func run() throws {
            let context = try Context.open()
            defer { context.close() }
            let status = LaunchAgentScheduler(context.settings).status()
            if json {
                outputJSON(status.asDictionary)
            } else if status.state == "loaded" {
                output("每日自动扫描：已启用，每天 \(status.time ?? "")")
                output("LaunchAgent：\(status.plistPath)")
            } else if status.state == "configured_not_loaded" {
                let suffix = status.time.map { "，计划时间 \($0)" } ?? ""
                output("每日自动扫描：已配置但未载入 launchd\(suffix)")
                output("LaunchAgent：\(status.plistPath)")
            } else {
                output("每日自动扫描：未配置")
            }
        }
    }

    struct ScheduleEnable: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "enable", abstract: "安装或更新当前用户的每日扫描 LaunchAgent。")

        @Option(name: .long, help: "每天运行时间，HH:MM") var at = "09:00"

        func run() throws {
            let context = try Context.open()
            defer { context.close() }
            do {
                let status = try LaunchAgentScheduler(context.settings).enable(at: at)
                output("每日自动扫描已启用：每天 \(status.time ?? at)")
                output("任务会始终扫描；只有显式启用 auto-confirm 时才会自动移动文件。")
            } catch {
                throw ValidationError("\(error)")
            }
        }
    }

    struct ScheduleDisable: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "disable", abstract: "卸载每日扫描 LaunchAgent。")

        func run() throws {
            let context = try Context.open()
            defer { context.close() }
            LaunchAgentScheduler(context.settings).disable()
            output("每日自动扫描已停用。")
        }
    }
}

// MARK: - auto

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "运行可供 launchd 和 GUI 调用的自动化工作流",
        subcommands: [AutoRun.self]
    )

    struct AutoRun: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run", abstract: "立即执行一次每日任务。")

        @Flag(name: .long) var json = false
        @Flag(name: .customLong("no-semantic")) var noSemantic = false

        func run() throws {
            let context = try Context.open()
            defer { context.close() }
            let result = try DailyAutomationService(context.db, context.settings)
                .run(useSemantic: !noSemantic)
            if json {
                outputJSON(result.asDictionary)
                return
            }
            let stats = result.scanStats
            output("扫描完成：新增/更新 \(stats.scanned)，未变化 \(stats.unchanged)，"
                + "跳过 \(stats.skipped)，提取错误 \(stats.errors)")
            if !result.autoConfirmEnabled {
                output("高置信度自动确认未启用；本次没有生成或执行移动方案。")
            } else if result.batchID == nil {
                output("方案 \(result.planID.map(String.init) ?? "") 没有达到阈值的无冲突分组；没有移动文件。")
            } else {
                let topics = (result.eligibleTopics ?? []).joined(separator: "、")
                output("自动确认方案 \(result.planID.map(String.init) ?? "")：\(topics)；"
                    + "批次 \(result.batchID.map(String.init) ?? "") 已移动 \(result.moved) 个，跳过 \(result.skipped) 个。")
            }
        }
    }
}

// MARK: - watch

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "以前台进程监控已配置文件夹；只更新索引，不移动文件。")

    @Option(help: "补扫间隔（秒）") var interval = 300

    func run() throws {
        let context = try Context.open()
        defer { context.close() }
        let settings = context.settings
        output("正在监控 \(settings.scanRoots.map(\.path).joined(separator: "、"))。按 Ctrl-C 停止。")
        let initial = try AppLock.withLock(settings.dataDir) {
            try Scanner.scan(context.db, settings, waitForStability: true)
        }
        output("初始索引：更新 \(initial.scanned) 个文件，\(initial.errors) 个错误")

        let wake = DispatchSemaphore(value: 0)
        var sources: [any DispatchSourceFileSystemObject] = []
        defer { sources.forEach { $0.cancel() } }
        for root in settings.scanRoots {
            let descriptor = open(root.path, O_EVTONLY)
            guard descriptor >= 0 else { throw OrganizerError("无法监控 \(root.path)") }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: .global()
            )
            source.setEventHandler { wake.signal() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }

        while true {
            _ = wake.wait(timeout: .now() + Double(interval))
            // Merge event bursts before the stability check.
            Thread.sleep(forTimeInterval: 1)
            let stats = try AppLock.withLock(settings.dataDir) {
                try Scanner.scan(context.db, settings, waitForStability: true)
            }
            if stats.scanned > 0 || stats.errors > 0 {
                output("索引已更新：\(stats.scanned) 个文件，\(stats.errors) 个错误")
            }
        }
    }
}
