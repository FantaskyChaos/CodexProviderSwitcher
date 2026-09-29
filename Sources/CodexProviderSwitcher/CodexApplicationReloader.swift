import AppKit
import Foundation

@MainActor
struct CodexApplicationReloader {
    static let bundleIdentifier = "com.openai.codex"
    // Codex may wait for the user to acknowledge its scheduled-task warning
    // before accepting the quit request. Keep this long enough for that flow.
    static let gracefulExitTimeout: TimeInterval = 90
    static let pollInterval: Duration = .milliseconds(250)
    static let progressUpdateInterval: TimeInterval = 2

    static func restartAndOpen(
        threadID: String,
        onStatus: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws {
        guard let taskURL = CodexDeepLink.taskURL(threadID: threadID) else {
            throw SwitcherError.invalidData("任务 ID 无法生成 Codex 打开链接")
        }

        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        for application in runningApps where !application.isTerminated {
            guard application.terminate() else {
                throw SwitcherError.invalidData("Codex 未接受正常退出请求，请手动退出后重试")
            }
        }

        if !runningApps.isEmpty {
            let deadline = Date().addingTimeInterval(gracefulExitTimeout)
            var nextStatusUpdate = Date()
            onStatus("正在等待 Codex 完成退出…")
            while runningApps.contains(where: { !$0.isTerminated }), Date() < deadline {
                let now = Date()
                if now >= nextStatusUpdate {
                    onStatus(
                        "正在等待 Codex 完成退出…如果出现定时任务提醒，请在 Codex 中完成确认；本工具不会修改或删除定时任务。"
                    )
                    nextStatusUpdate = now.addingTimeInterval(progressUpdateInterval)
                }
                try await Task.sleep(for: pollInterval)
            }
            guard runningApps.allSatisfy(\.isTerminated) else {
                throw SwitcherError.invalidData(
                    "Codex 在 \(Int(gracefulExitTimeout)) 秒内仍未完成退出。任务修改已保存；请先处理 Codex 中的定时任务提示，再重试。"
                )
            }
        }

        onStatus("Codex 已退出，正在重新打开目标任务…")
        guard NSWorkspace.shared.open(taskURL) else {
            throw SwitcherError.invalidData("无法重新打开 Codex；任务修改已经安全保存")
        }
    }
}
