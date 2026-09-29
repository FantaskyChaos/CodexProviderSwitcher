import CSQLite
import Darwin
import Foundation

struct CodexStore: @unchecked Sendable {
    let codexHome: URL

    init(codexHome: URL? = nil) {
        if let codexHome {
            self.codexHome = codexHome
        } else if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            self.codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            self.codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
    }

    var stateDatabaseURL: URL {
        codexHome.appendingPathComponent("state_5.sqlite")
    }

    var configURL: URL {
        codexHome.appendingPathComponent("config.toml")
    }

    var sessionIndexURL: URL {
        codexHome.appendingPathComponent("session_index.jsonl")
    }

    func loadTasks() throws -> [CodexTask] {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            throw SwitcherError.missingFile("找不到 Codex 任务数据库：\(stateDatabaseURL.path)")
        }

        let indexedTitles = loadIndexedTitles()
        return try withDatabase(at: stateDatabaseURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) { db in
            let sql = """
            SELECT id, title, preview, model_provider, model, rollout_path,
                   updated_at, archived, source, thread_source, cwd
            FROM threads
            ORDER BY updated_at DESC, id DESC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(db, prefix: "无法读取任务")
            }
            defer { sqlite3_finalize(statement) }

            var tasks: [CodexTask] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = columnText(statement, 0)
                let title = columnText(statement, 1)
                let preview = columnText(statement, 2)
                let provider = columnText(statement, 3)
                let model = columnOptionalText(statement, 4)
                let rolloutPath = columnText(statement, 5)
                let updatedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 6)))
                let archived = sqlite3_column_int(statement, 7) != 0
                let source = columnText(statement, 8)
                let threadSource = columnOptionalText(statement, 9)
                let workspacePath = columnText(statement, 10)
                tasks.append(
                    CodexTask(
                        id: id,
                        title: title,
                        preview: preview,
                        indexedTitle: indexedTitles[id],
                        provider: provider,
                        model: model,
                        rolloutPath: rolloutPath,
                        workspacePath: workspacePath,
                        updatedAt: updatedAt,
                        archived: archived,
                        threadSource: threadSource,
                        parentThreadID: parentThreadID(from: source, threadSource: threadSource)
                    )
                )
            }
            return tasks
        }
    }

    func waitForTask(
        id: String,
        timeout: TimeInterval = 5
    ) throws -> CodexTask {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let task = try loadTasks().first(where: { $0.id == id }) {
                return task
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw SwitcherError.invalidData("Codex 已返回新分支，但任务目录尚未出现该任务：\(id)")
    }

    private func loadIndexedTitles() -> [String: String] {
        guard let source = try? String(contentsOf: sessionIndexURL, encoding: .utf8) else {
            return [:]
        }
        var titles: [String: String] = [:]
        for line in source.split(whereSeparator: \Character.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let title = object["thread_name"] as? String,
                  !id.isEmpty,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            // session_index.jsonl is append-only; the final valid record for
            // a thread is the same title Codex currently presents.
            titles[id] = title
        }
        return titles
    }

    func loadProviderConfiguration() throws -> ProviderConfiguration {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw SwitcherError.missingFile("找不到 Codex 配置：\(configURL.path)")
        }
        let source = try String(contentsOf: configURL, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)
        let activeRegex = try NSRegularExpression(
            pattern: #"^\s*model_provider\s*=\s*"([^"]+)"\s*(?:#.*)?$"#
        )
        let providerRegex = try NSRegularExpression(
            pattern: #"^\s*\[model_providers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))\]\s*(?:#.*)?$"#
        )

        var activeProvider = "openai"
        var providerIDs: Set<String> = ["openai"]
        var reachedTable = false

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                reachedTable = true
            }
            if !reachedTable,
               let match = activeRegex.firstMatch(in: line, range: range),
               let valueRange = Range(match.range(at: 1), in: line) {
                activeProvider = String(line[valueRange])
                providerIDs.insert(activeProvider)
            }
            if let match = providerRegex.firstMatch(in: line, range: range) {
                for index in [1, 2] where match.range(at: index).location != NSNotFound {
                    if let valueRange = Range(match.range(at: index), in: line) {
                        providerIDs.insert(String(line[valueRange]))
                    }
                }
            }
        }

        providerIDs.insert(activeProvider)
        let providers = providerIDs
            .map { ProviderOption(id: $0, displayName: ProviderOption.displayName(for: $0)) }
            .sorted {
                if $0.id == activeProvider { return true }
                if $1.id == activeProvider { return false }
                if $0.id == "openai" { return true }
                if $1.id == "openai" { return false }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        return ProviderConfiguration(activeProvider: activeProvider, providers: providers)
    }

    func preflight(task: CodexTask, targetProvider: String) throws -> ContextPreflight {
        try preflight(tasks: [task], targetProvider: targetProvider)
    }

    func preflight(
        tasks: [CodexTask],
        targetProvider: String
    ) throws -> ContextPreflight {
        let pendingTasks = tasks.filter { $0.provider != targetProvider }
        let compatibilityFixes = try tasks.reduce(into: 0) { total, task in
            total += try officialCompatibilityFixCount(
                task: task,
                targetProvider: targetProvider
            )
        }
        if pendingTasks.isEmpty && compatibilityFixes == 0 {
            return ContextPreflight(
                level: .alreadyTarget,
                latestInputTokens: nil,
                currentContextWindow: nil,
                targetContextWindow: nil,
                guardrailTokens: nil,
                headroomTokens: nil,
                compactedEvents: 0,
                compatibilityFixes: 0,
                message: "任务已经使用该提供商"
            )
        }

        let subagentCount = max(0, tasks.count - 1)
        guard let primaryTask = tasks.first else {
            return ContextPreflight(
                level: .blockedUnknown,
                latestInputTokens: nil,
                currentContextWindow: nil,
                targetContextWindow: nil,
                guardrailTokens: nil,
                headroomTokens: nil,
                compactedEvents: 0,
                compatibilityFixes: compatibilityFixes,
                message: "没有可检查的主任务"
            )
        }

        // Child metadata changes do not resume child threads, so only the main
        // task needs a compaction preflight. Descendants are synchronized in
        // the same guarded migration without being opened.
        if primaryTask.provider == targetProvider {
            let providerMessage = pendingTasks.isEmpty
                ? "任务已使用目标提供商"
                : "主任务已是目标提供商；将同步 \(pendingTasks.count) 个子代理"
            let compatibilityMessage = compatibilityFixes > 0
                ? "；将修复 \(compatibilityFixes) 条官方工具 ID"
                : ""
            return ContextPreflight(
                level: .safe,
                latestInputTokens: nil,
                currentContextWindow: nil,
                targetContextWindow: nil,
                guardrailTokens: nil,
                headroomTokens: nil,
                compactedEvents: 0,
                compatibilityFixes: compatibilityFixes,
                message: providerMessage + compatibilityMessage
            )
        }

        let targetWindow = try observedContextWindows(
            provider: targetProvider,
            model: primaryTask.model
        ).min()
        let check = try preflightTask(
            task: primaryTask,
            targetProvider: targetProvider,
            targetWindow: targetWindow
        )
        let subagentMessage = subagentCount > 0
            ? "；将同时同步 \(subagentCount) 个子代理"
            : ""
        let compatibilityMessage = compatibilityFixes > 0
            ? "；将修复 \(compatibilityFixes) 条官方工具 ID"
            : ""
        return ContextPreflight(
            level: check.level,
            latestInputTokens: check.latestInputTokens,
            currentContextWindow: check.currentContextWindow,
            targetContextWindow: check.targetContextWindow,
            guardrailTokens: check.guardrailTokens,
            headroomTokens: check.headroomTokens,
            compactedEvents: check.compactedEvents,
            compatibilityFixes: compatibilityFixes,
            message: check.message + subagentMessage + compatibilityMessage
        )
    }

    private func preflightTask(
        task: CodexTask,
        targetProvider: String,
        targetWindow: Int?
    ) throws -> ContextPreflight {
        let rolloutURL = URL(fileURLWithPath: task.rolloutPath)
        let state = try rolloutContextState(at: rolloutURL)

        guard let latestInput = state.latestInputTokens, let targetWindow else {
            return ContextPreflight(
                level: .blockedUnknown,
                latestInputTokens: state.latestInputTokens,
                currentContextWindow: state.latestContextWindow,
                targetContextWindow: targetWindow,
                guardrailTokens: nil,
                headroomTokens: nil,
                compactedEvents: state.compactedEvents,
                compatibilityFixes: 0,
                message: "缺少可靠的上下文容量数据，切换前需要确认风险"
            )
        }

        let guardrail = Int(Double(targetWindow) * 0.8)
        let headroom = guardrail - latestInput
        if latestInput >= guardrail {
            return ContextPreflight(
                level: .blockedRisk,
                latestInputTokens: latestInput,
                currentContextWindow: state.latestContextWindow,
                targetContextWindow: targetWindow,
                guardrailTokens: guardrail,
                headroomTokens: headroom,
                compactedEvents: state.compactedEvents,
                compatibilityFixes: 0,
                message: "当前上下文超过质量保护线，切换可能触发压缩"
            )
        }

        return ContextPreflight(
            level: .safe,
            latestInputTokens: latestInput,
            currentContextWindow: state.latestContextWindow,
            targetContextWindow: targetWindow,
            guardrailTokens: guardrail,
            headroomTokens: headroom,
            compactedEvents: state.compactedEvents,
            compatibilityFixes: 0,
            message: "安全余量约 \(headroom.formatted()) tokens"
        )
    }

    func switchTask(
        task: CodexTask,
        targetProvider: String,
        allowRisk: Bool = false
    ) throws -> SwitchResult {
        try switchTasks(
            tasks: [task],
            targetProvider: targetProvider,
            allowRisk: allowRisk
        )
    }

    func switchTasks(
        tasks: [CodexTask],
        targetProvider: String,
        allowRisk: Bool = false
    ) throws -> SwitchResult {
        let pendingTasks = tasks.filter { $0.provider != targetProvider }
        let check = try preflight(tasks: tasks, targetProvider: targetProvider)
        if check.level == .alreadyTarget {
            throw SwitcherError.invalidData("任务已经使用 \(ProviderOption.displayName(for: targetProvider))")
        }
        if !allowRisk && (check.level == .blockedRisk || check.level == .blockedUnknown) {
            throw SwitcherError.unsafe(check.message)
        }

        var tasksToRewrite: [CodexTask] = []
        for task in tasks {
            let fixes = try officialCompatibilityFixCount(
                task: task,
                targetProvider: targetProvider
            )
            if task.provider != targetProvider || fixes > 0 {
                tasksToRewrite.append(task)
            }
        }

        for task in tasksToRewrite {
            guard FileManager.default.fileExists(atPath: task.rolloutPath) else {
                throw SwitcherError.missingFile("找不到任务历史：\(task.rolloutPath)")
            }
        }

        let databaseBackup = try backupDatabase()
        var rolloutBackups: [(task: CodexTask, source: URL, backup: URL)] = []
        var changedRecords = 0
        var compatibilityFixes = 0

        do {
            for task in tasksToRewrite {
                let rolloutURL = URL(fileURLWithPath: task.rolloutPath)
                let rolloutBackup = try uniqueBackupURL(
                    for: rolloutURL,
                    label: "provider-switch"
                )
                try FileManager.default.copyItem(at: rolloutURL, to: rolloutBackup)
                rolloutBackups.append((task, rolloutURL, rolloutBackup))
                let rewrite = try rewriteRollout(
                    at: rolloutURL,
                    expectedThreadID: task.id,
                    provider: targetProvider
                )
                guard rewrite.providerRecords > 0 else {
                    throw SwitcherError.invalidData(
                        "任务 \(task.id) 的历史中没有可修改的 provider 元数据"
                    )
                }
                changedRecords += rewrite.changedRecords
                compatibilityFixes += rewrite.compatibilityFixes
            }
            if !pendingTasks.isEmpty {
                try updateDatabaseProviders(tasks: pendingTasks, to: targetProvider)
            }
            return SwitchResult(
                changedTasks: tasksToRewrite.count,
                changedRecords: changedRecords,
                rolloutBackups: rolloutBackups.map { $0.backup.path },
                databaseBackup: databaseBackup.path,
                compatibilityFixes: compatibilityFixes
            )
        } catch {
            for item in rolloutBackups {
                try? restoreFile(from: item.backup, to: item.source)
            }
            throw error
        }
    }

    func rolloutContextState(at url: URL) throws -> RolloutContextState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwitcherError.missingFile("找不到任务历史：\(url.path)")
        }
        var state = RolloutContextState(
            compactedEvents: try countCompactions(at: url)
        )
        let data = try readTail(at: url, maximumBytes: 4 * 1_048_576)
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(rawLine)
            guard line.range(of: Data("model_context_window".utf8)) != nil
                    || line.range(of: Data("input_tokens".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                continue
            }
            if payloadType == "task_started",
               let value = number(payload["model_context_window"]) {
                state.latestContextWindow = value
            } else if payloadType == "token_count",
                      let info = payload["info"] as? [String: Any] {
                if let usage = info["last_token_usage"] as? [String: Any],
                   let value = number(usage["input_tokens"]) {
                    state.latestInputTokens = value
                }
                if let value = number(info["model_context_window"]) {
                    state.latestContextWindow = value
                }
            }
        }

        if state.latestInputTokens != nil && state.latestContextWindow != nil {
            return state
        }

        return try rolloutContextStateFull(at: url, compactedEvents: state.compactedEvents)
    }

    private func rolloutContextStateFull(
        at url: URL,
        compactedEvents: Int
    ) throws -> RolloutContextState {
        var state = RolloutContextState(compactedEvents: compactedEvents)
        try forEachLine(in: url) { data, _ in
            let couldContainContext = data.range(of: Data("token_count".utf8)) != nil
                || data.range(of: Data("task_started".utf8)) != nil
            guard couldContainContext else {
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                return
            }
            guard type == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                return
            }
            if payloadType == "task_started",
               let value = number(payload["model_context_window"]) {
                state.latestContextWindow = value
            } else if payloadType == "token_count",
                      let info = payload["info"] as? [String: Any] {
                if let usage = info["last_token_usage"] as? [String: Any],
                   let value = number(usage["input_tokens"]) {
                    state.latestInputTokens = value
                }
                if let value = number(info["model_context_window"]) {
                    state.latestContextWindow = value
                }
            }
        }
        return state
    }

    private func observedContextWindows(provider: String, model: String?) throws -> [Int] {
        let rows: [String] = try withDatabase(
            at: stateDatabaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        ) { db in
            let sql: String
            if model == nil {
                sql = "SELECT rollout_path FROM threads WHERE model_provider = ?"
            } else {
                sql = "SELECT rollout_path FROM threads WHERE model_provider = ? AND model = ?"
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(db, prefix: "无法读取上下文容量")
            }
            defer { sqlite3_finalize(statement) }
            bindText(provider, to: statement, index: 1)
            if let model {
                bindText(model, to: statement, index: 2)
            }
            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(columnText(statement, 0))
            }
            return values
        }

        var windows: Set<Int> = []
        for path in rows where FileManager.default.fileExists(atPath: path) {
            if let value = try? latestContextWindow(
                at: URL(fileURLWithPath: path)
            ) {
                windows.insert(value)
            }
        }
        return windows.sorted()
    }

    private func latestContextWindow(at url: URL) throws -> Int? {
        let data = try readTail(at: url, maximumBytes: 4 * 1_048_576)

        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            let line = Data(rawLine)
            guard line.range(of: Data("model_context_window".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                continue
            }
            if payloadType == "token_count",
               let info = payload["info"] as? [String: Any],
               let value = number(info["model_context_window"]) {
                return value
            }
            if payloadType == "task_started",
               let value = number(payload["model_context_window"]) {
                return value
            }
        }

        return try rolloutContextState(at: url).latestContextWindow
    }

    private func readTail(at url: URL, maximumBytes: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: fileSize > maximumBytes ? fileSize - maximumBytes : 0)
        return try handle.readToEnd() ?? Data()
    }

    private func countCompactions(at url: URL) throws -> Int {
        let needle = Data(#""type":"compacted""#.utf8)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var count = 0
        var overlap = Data()

        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            var searchable = overlap
            searchable.append(chunk)
            var searchRange = searchable.startIndex..<searchable.endIndex
            while let range = searchable.range(of: needle, in: searchRange) {
                count += 1
                searchRange = range.upperBound..<searchable.endIndex
            }
            let overlapCount = min(needle.count - 1, searchable.count)
            overlap = searchable.suffix(overlapCount)
        }
        return count
    }

    private func rewriteRollout(
        at url: URL,
        expectedThreadID: String,
        provider: String
    ) throws -> (changedRecords: Int, compatibilityFixes: Int, providerRecords: Int) {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryURL)
        var changed = 0
        var compatibilityFixes = 0
        var providerRecords = 0
        var foundThreadID: String?
        let providerRegex = try NSRegularExpression(
            pattern: #""model_provider"\s*:\s*"[^"]+""#
        )

        do {
            try forEachLine(in: url) { data, hadNewline in
                var outputData = data
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["type"] as? String == "session_meta",
                   let payload = object["payload"] as? [String: Any] {
                    if foundThreadID == nil {
                        foundThreadID = (payload["id"] as? String) ?? (payload["session_id"] as? String)
                    }
                    if payload["model_provider"] is String,
                       let line = String(data: data, encoding: .utf8) {
                        providerRecords += 1
                        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
                        let replacement = #""model_provider":"\#(provider)""#
                        let updated = providerRegex.stringByReplacingMatches(
                            in: line,
                            range: fullRange,
                            withTemplate: replacement
                        )
                        if updated != line {
                            changed += 1
                            outputData = Data(updated.utf8)
                        }
                    }
                } else if provider == "openai",
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["type"] as? String == "response_item",
                          let payload = object["payload"] as? [String: Any],
                          payload["type"] as? String == "tool_search_call",
                          let identifier = payload["id"] as? String,
                          let corrected = officialToolSearchIdentifier(identifier),
                          let line = String(data: data, encoding: .utf8) {
                    let escaped = NSRegularExpression.escapedPattern(for: identifier)
                    let identifierRegex = try NSRegularExpression(
                        pattern: #""id"\s*:\s*"\#(escaped)""#
                    )
                    let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
                    let updated = identifierRegex.stringByReplacingMatches(
                        in: line,
                        options: [],
                        range: fullRange,
                        withTemplate: #""id":"\#(corrected)""#
                    )
                    if updated != line {
                        changed += 1
                        compatibilityFixes += 1
                        outputData = Data(updated.utf8)
                    }
                }
                try output.write(contentsOf: outputData)
                if hadNewline {
                    try output.write(contentsOf: Data([0x0A]))
                }
            }
            try output.synchronize()
            try output.close()

            guard foundThreadID == expectedThreadID else {
                throw SwitcherError.invalidData(
                    "任务 ID 不匹配：数据库为 \(expectedThreadID)，历史文件为 \(foundThreadID ?? "未知")"
                )
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: temporaryURL.path
                )
            }
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw SwitcherError.invalidData(
                    "无法原子替换任务历史：\(String(cString: strerror(errno)))"
                )
            }
            return (changed, compatibilityFixes, providerRecords)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func officialCompatibilityFixCount(
        task: CodexTask,
        targetProvider: String
    ) throws -> Int {
        guard targetProvider == "openai" else { return 0 }
        let url = URL(fileURLWithPath: task.rolloutPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwitcherError.missingFile("找不到任务历史：\(url.path)")
        }
        var count = 0
        try forEachLine(in: url) { data, _ in
            guard data.range(of: Data(#""tool_search_call""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "tool_search_call",
                  let identifier = payload["id"] as? String,
                  officialToolSearchIdentifier(identifier) != nil else {
                return
            }
            count += 1
        }
        return count
    }

    private func officialToolSearchIdentifier(_ identifier: String) -> String? {
        guard identifier.hasPrefix("ts_"), !identifier.hasPrefix("tsc_") else {
            return nil
        }
        return "tsc_" + identifier.dropFirst(3)
    }

    private func updateDatabaseProviders(
        tasks: [CodexTask],
        to targetProvider: String
    ) throws {
        try withDatabase(
            at: stateDatabaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        ) { db in
            sqlite3_busy_timeout(db, 10_000)
            try execute(db, sql: "BEGIN IMMEDIATE")
            do {
                var statement: OpaquePointer?
                let sql = "UPDATE threads SET model_provider = ? WHERE id = ? AND model_provider = ?"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw databaseError(db, prefix: "无法准备任务更新")
                }
                defer { sqlite3_finalize(statement) }
                for task in tasks {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindText(targetProvider, to: statement, index: 1)
                    bindText(task.id, to: statement, index: 2)
                    bindText(task.provider, to: statement, index: 3)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw databaseError(db, prefix: "无法更新任务提供商")
                    }
                    guard sqlite3_changes(db) == 1 else {
                        throw SwitcherError.database(
                            "任务 \(task.id) 的状态已发生变化，请刷新后重试"
                        )
                    }
                }

                var check: OpaquePointer?
                guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK,
                      sqlite3_step(check) == SQLITE_ROW,
                      columnText(check, 0) == "ok" else {
                    sqlite3_finalize(check)
                    throw SwitcherError.database("SQLite 完整性检查失败")
                }
                sqlite3_finalize(check)
                try execute(db, sql: "COMMIT")
            } catch {
                try? execute(db, sql: "ROLLBACK")
                throw error
            }
        }
    }

    private func backupDatabase() throws -> URL {
        let backupURL = try uniqueBackupURL(for: stateDatabaseURL, label: "provider-switch")
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            stateDatabaseURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            defer { sqlite3_close(source) }
            throw databaseError(source, prefix: "无法打开任务数据库")
        }
        defer { sqlite3_close(source) }

        guard sqlite3_open_v2(
            backupURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            defer { sqlite3_close(destination) }
            throw databaseError(destination, prefix: "无法创建数据库备份")
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw databaseError(destination, prefix: "无法初始化数据库备份")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE && finish == SQLITE_OK else {
            try? FileManager.default.removeItem(at: backupURL)
            throw databaseError(destination, prefix: "数据库备份失败")
        }
        return backupURL
    }

    private func restoreFile(from backup: URL, to destination: URL) throws {
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).restore.\(UUID().uuidString)")
        try FileManager.default.copyItem(at: backup, to: temporaryURL)
        guard rename(temporaryURL.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw SwitcherError.invalidData("无法恢复任务历史备份")
        }
    }

    private func uniqueBackupURL(for url: URL, label: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(label)-\(stamp).bak")
        var sequence = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(url.lastPathComponent).\(label)-\(stamp)-\(sequence).bak"
                )
            sequence += 1
        }
        return candidate
    }

    private func forEachLine(
        in url: URL,
        _ body: (Data, Bool) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        let newline = Data([0x0A])

        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            buffer.append(chunk)
            while let range = buffer.range(of: newline) {
                let line = Data(buffer[..<range.lowerBound])
                try body(line, true)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            }
        }
        if !buffer.isEmpty {
            try body(buffer, false)
        }
    }

    private func withDatabase<T>(
        at url: URL,
        flags: Int32,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }
            throw databaseError(database, prefix: "无法打开数据库")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errorMessage)
            throw SwitcherError.database(message)
        }
    }

    private func databaseError(_ db: OpaquePointer?, prefix: String) -> SwitcherError {
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
        return .database("\(prefix)：\(detail)")
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func columnOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func parentThreadID(
        from source: String,
        threadSource: String?
    ) -> String? {
        guard threadSource == "subagent",
              let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagent = object["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any],
              let parent = spawn["parent_thread_id"] as? String,
              !parent.isEmpty else {
            return nil
        }
        return parent
    }
}
