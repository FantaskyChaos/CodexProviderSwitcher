import SwiftUI

@main
struct CodexProviderSwitcherApp: App {
    @StateObject private var model: AppModel

    init() {
        let appModel = AppModel()
        _model = StateObject(wrappedValue: appModel)
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--reload-codex-thread"),
           arguments.indices.contains(flagIndex + 1) {
            let threadID = arguments[flagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                appModel.restartCodexAndOpen(threadID: threadID)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Codex 提供商切换") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1320, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("刷新任务") {
                    model.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
