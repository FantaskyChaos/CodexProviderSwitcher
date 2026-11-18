import Foundation

struct CodexForkClient: @unchecked Sendable {
    private let executableURL: URL?
    private let timeout: TimeInterval

    init(executableURL: URL? = nil, timeout: TimeInterval = 60) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func forkThread(
        threadID: String,
        modelProvider: String,
        lastTurnID: String? = nil,
        ephemeral: Bool = false
    ) throws -> String {
        guard UUID(uuidString: threadID) != nil else {
            throw SwitcherError.invalidData("源任务 ID 无效，无法创建分支")
        }

        let executable = try executableURL ?? Self.locateCodexExecutable()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let state = ForkProcessState()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                state.finish()
            } else {
                state.consumeStandardOutput(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                state.consumeStandardError(data)
            }
        }
        process.terminationHandler = { _ in
            state.finish()
        }

        do {
            try process.run()
            let requests = try CodexForkProtocol.requestPayload(
                threadID: threadID,
                modelProvider: modelProvider,
                lastTurnID: lastTurnID,
                ephemeral: ephemeral
            )
            try inputPipe.fileHandleForWriting.write(contentsOf: requests)
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            throw SwitcherError.invalidData("无法启动 Codex 分支服务：\(error.localizedDescription)")
        }

        let waitResult = state.semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw SwitcherError.invalidData("Codex 创建分支超时，原任务未修改")
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        return try state.result()
    }

    private static func locateCodexExecutable() throws -> URL {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        throw SwitcherError.missingFile("找不到 Codex 程序，请确认 ChatGPT/Codex 已安装")
    }
}

enum CodexForkProtocol {
    static func requestPayload(
        threadID: String,
        modelProvider: String,
        lastTurnID: String?,
        ephemeral: Bool
    ) throws -> Data {
        var forkParameters: [String: Any] = [
            "threadId": threadID,
            "modelProvider": modelProvider,
            "ephemeral": ephemeral
        ]
        if let lastTurnID, !lastTurnID.isEmpty {
            forkParameters["lastTurnId"] = lastTurnID
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "codex_provider_switcher",
                        "title": "Codex Provider Switcher",
                        "version": "1.6.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            ["method": "thread/fork", "id": 2, "params": forkParameters]
        ]

        var payload = Data()
        for message in messages {
            payload.append(try JSONSerialization.data(withJSONObject: message))
            payload.append(0x0A)
        }
        return payload
    }
}

struct CodexForkResponseScanner {
    private(set) var threadID: String?
    private(set) var errorMessage: String?
    private var prefix = Data()
    private let maximumPrefixBytes = 512 * 1024

    mutating func consume(_ data: Data) {
        guard threadID == nil, errorMessage == nil, prefix.count < maximumPrefixBytes else {
            return
        }
        prefix.append(data.prefix(maximumPrefixBytes - prefix.count))
        let text = String(decoding: prefix, as: UTF8.self)

        if text.contains("\"result\"") {
            let expression = try? NSRegularExpression(
                pattern: #""thread"\s*:\s*\{\s*"id"\s*:\s*"([0-9A-Fa-f-]{36})""#
            )
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = expression?.firstMatch(in: text, range: fullRange),
               let valueRange = Range(match.range(at: 1), in: text) {
                let value = String(text[valueRange])
                if UUID(uuidString: value) != nil {
                    threadID = value
                    return
                }
            }
        }

        if let errorRange = text.range(of: "\"error\""),
           let message = jsonStringValue(for: "message", in: text, after: errorRange.upperBound) {
            errorMessage = message
        }
    }

    private func jsonStringValue(
        for key: String,
        in text: String,
        after start: String.Index
    ) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"", range: start..<text.endIndex),
              let colon = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }
        let remainder = text[text.index(after: colon)...]
        guard let openingQuote = remainder.firstIndex(where: { !$0.isWhitespace }),
              text[openingQuote] == "\"" else {
            return nil
        }
        let valueStart = text.index(after: openingQuote)
        guard let closingQuote = text[valueStart...].firstIndex(of: "\"") else {
            return nil
        }
        return String(text[valueStart..<closingQuote])
    }
}

private final class ForkProcessState: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var scanner = CodexForkResponseScanner()
    private var standardError = Data()
    private var completed = false

    func consumeStandardOutput(_ data: Data) {
        let shouldSignal = lock.withLock {
            scanner.consume(data)
            guard !completed,
                  scanner.threadID != nil || scanner.errorMessage != nil else {
                return false
            }
            completed = true
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func consumeStandardError(_ data: Data) {
        lock.withLock {
            if standardError.count < 64 * 1024 {
                standardError.append(data.prefix(64 * 1024 - standardError.count))
            }
        }
    }

    func finish() {
        let shouldSignal = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }

    func result() throws -> String {
        try lock.withLock {
            if let threadID = scanner.threadID {
                return threadID
            }
            if let message = scanner.errorMessage, !message.isEmpty {
                throw SwitcherError.invalidData("Codex 无法创建分支：\(message)")
            }
            let diagnostic = String(decoding: standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !diagnostic.isEmpty {
                throw SwitcherError.invalidData("Codex 分支服务未返回新任务：\(diagnostic)")
            }
            throw SwitcherError.invalidData("Codex 分支服务未返回新任务")
        }
    }
}
