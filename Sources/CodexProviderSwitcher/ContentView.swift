import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: WorkspacePage = .tasks

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                switch page {
                case .tasks:
                    HSplitView {
                        WorkspaceSidebar()
                            .frame(minWidth: 190, idealWidth: 215, maxWidth: 260, maxHeight: .infinity)
                        HSplitView {
                            taskList
                                .frame(minWidth: 520, maxHeight: .infinity)
                            inspector
                                .frame(minWidth: 310, idealWidth: 350, maxWidth: 410, maxHeight: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                case .mindMap:
                    HSplitView {
                        WorkspaceSidebar()
                            .frame(minWidth: 190, idealWidth: 215, maxWidth: 260, maxHeight: .infinity)
                        MindMapView()
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(minHeight: 0)
            .layoutPriority(1)
            Divider()
            statusBar
        }
        .frame(minWidth: 1120, minHeight: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: page) { _, newPage in
            if newPage == .mindMap {
                model.prepareMindMapSelection()
            }
        }
        .alert("可能影响上下文质量", isPresented: $model.showRiskAlert) {
            Button("取消", role: .cancel) {}
            Button("仍然切换", role: .destructive) {
                model.forceSwitch()
            }
        } message: {
            Text("\(model.preflight.message)\n\n强制切换仍会保留 JSONL 和数据库备份。")
        }
        .alert("创建独立分支", isPresented: $model.showForkConfirmation) {
            Button("取消", role: .cancel) {}
            Button("创建分支") {
                model.confirmForkAndSwitch()
            }
        } message: {
            Text("将复制所选任务截至最新已完成位置的历史，并把新分支设为 \(ProviderOption.displayName(for: model.targetProviderID))。\n\n原任务和其子代理保持不变，不会发送消息或调用模型。")
        }
        .alert("新分支可能影响上下文质量", isPresented: $model.showForkRiskAlert) {
            Button("取消", role: .cancel) {}
            Button("仍然创建", role: .destructive) {
                model.forceForkAndSwitch()
            }
        } message: {
            Text("\(model.preflight.message)\n\n这只会创建和切换新分支，原任务保持不变。")
        }
        .alert(model.resultAlertTitle, isPresented: $model.showResultAlert) {
            Button("重启并打开 Codex") {
                if let task = model.selectedTask { model.restartCodexAndOpen(threadID: task.id) }
            }
            Button("仅在 Codex 中打开") {
                if let task = model.selectedTask { model.openInCodex(task) }
            }
            Button("稍后处理", role: .cancel) {}
        } message: {
            Text(model.resultAlertMessage)
        }
        .alert("无法读取当前会话", isPresented: $model.showCurrentTaskAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.currentTaskAlertMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 会话管理")
                    .font(.title2.weight(.semibold))
                Text(page == .tasks ? "管理供应商与任务状态" : "整理会话之间的推进与分工关系")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("页面", selection: $page) {
                ForEach(WorkspacePage.allCases) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            Button {
                if model.switchCurrentCodexTask() { page = .tasks }
            } label: {
                Label("切换当前会话", systemImage: "scope")
            }
            .disabled(model.isBusy)
            .help("读取 Codex 主窗口当前会话，并切换到当前全局供应商")
            Label(
                "当前全局：\(ProviderOption.displayName(for: model.activeProvider))",
                systemImage: "checkmark.shield.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            Button {
                model.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索任务、模型或 ID", text: $model.searchText)
                    .textFieldStyle(.plain)
                Toggle("包含归档", isOn: $model.showArchived)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5))

            Table(
                model.filteredTasks,
                selection: Binding(
                    get: { model.selectedTaskIDs },
                    set: { model.setTaskSelection($0) }
                )
            ) {
                TableColumn("任务") { task in
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            model.toggleImportant(task)
                        } label: {
                            Image(systemName: model.isImportant(task) ? "star.fill" : "star")
                                .foregroundStyle(model.isImportant(task) ? Color.orange : Color.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(model.isImportant(task) ? "取消重要标记" : "标记为重要并置顶")

                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.displayTitle)
                                .lineLimit(2)
                                .font(.callout.weight(model.isImportant(task) ? .semibold : .medium))
                            if model.isInProgress(task) {
                                Text("进行中")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                            }
                            Text(task.id)
                                .lineLimit(1)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            let subagentCount = model.descendants(of: task.id).count
                            if subagentCount > 0 {
                                Label("\(subagentCount) 个子代理", systemImage: "person.2.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(
                        model.isImportant(task) ? Color.orange.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                .width(min: 230, ideal: 290, max: 330)

                TableColumn("提供商") { task in
                    providerBadge(task.provider)
                }
                .width(92)

                TableColumn("模型") { task in
                    Text(task.model ?? "—")
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(92)

                TableColumn("最近更新") { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.updatedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                        if task.archived {
                            Text("已归档")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .width(94)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let task = model.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.selectedRootTaskCount > 1 ? "批量选择" : "所选任务")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(
                            model.selectedRootTaskCount > 1
                                ? "已选择 \(model.selectedRootTaskCount) 个主任务"
                                : task.displayTitle
                        )
                            .font(.headline)
                            .textSelection(.enabled)
                        Text(
                            model.selectedRootTaskCount > 1
                                ? "连同子代理共 \(model.selectedTaskGroup.count) 个线程；完成后只重启一次"
                                : task.id
                        )
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)

                        if model.selectedRootTaskCount == 1 {
                            Button {
                                model.toggleImportant(task)
                            } label: {
                                Label(
                                    model.isImportant(task) ? "取消重要标记" : "标记为重要并置顶",
                                    systemImage: model.isImportant(task) ? "star.slash" : "star"
                                )
                            }
                            .buttonStyle(.bordered)
                            .tint(model.isImportant(task) ? .orange : .accentColor)

                            Button {
                                model.toggleInProgress(task)
                            } label: {
                                Label(
                                    model.isInProgress(task) ? "取消进行中标签" : "标记为进行中",
                                    systemImage: model.isInProgress(task) ? "pause.circle" : "play.circle"
                                )
                            }
                            .buttonStyle(.bordered)
                            .tint(model.isInProgress(task) ? .blue : .accentColor)

                            Button {
                                model.openInCodex(task)
                            } label: {
                                Label("在 Codex 中打开", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .help("通知 Codex 刷新任务目录并打开此任务，不会发送消息")

                            Button {
                                model.restartCodexAndOpen(threadID: task.id)
                            } label: {
                                Label("重启并打开", systemImage: "arrow.clockwise.circle")
                            }
                            .buttonStyle(.bordered)
                            .help("安全退出并重新打开 Codex，等待定时任务提示处理完成后再打开此任务")
                        }
                    }

                    infoCard(task: task)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("目标提供商")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("目标提供商", selection: $model.targetProviderID) {
                            ForEach(model.providers) { provider in
                                Text(provider.displayName).tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    riskCard

                    Button {
                        model.requestSwitch()
                    } label: {
                        HStack {
                            Spacer()
                            if model.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.left.arrow.right")
                            }
                            Text(switchButtonTitle(task: task))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canSwitch)

                    Button {
                        model.requestForkAndSwitch()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.triangle.branch")
                            Text(forkButtonTitle(task: task))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!model.canForkAndSwitch)
                    .help("使用 Codex 官方分支功能，原任务不变")

                    Text("直接切换会备份后修改原任务；新建分支会保留原任务。完成后 App 会把 Codex 置于前台，等待你处理可能出现的定时任务退出提醒，然后自动重新打开目标会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
            }
        } else {
            ContentUnavailableView(
                "请选择任务",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("从左侧任务列表中选择一个任务")
            )
        }
    }

    private func infoCard(task: CodexTask) -> some View {
        VStack(spacing: 10) {
            if model.selectedRootTaskCount > 1 {
                infoRow(label: "主任务", value: "\(model.selectedRootTaskCount) 个")
                infoRow(label: "全部线程", value: "\(model.selectedTaskGroup.count) 个")
                infoRow(
                    label: "当前提供商",
                    value: Set(model.selectedRootTasks.map { ProviderOption.displayName(for: $0.provider) })
                        .sorted()
                        .joined(separator: "、")
                )
                infoRow(label: "重启次数", value: "1 次")
            } else {
                infoRow(label: "当前提供商", value: ProviderOption.displayName(for: task.provider))
                infoRow(label: "模型", value: task.model ?? "未知")
                infoRow(label: "状态", value: task.archived ? "已归档" : "活跃")
                if model.isInProgress(task) {
                    infoRow(label: "标签", value: "进行中")
                }
                let subagentCount = model.selectedSubagents.count
                if subagentCount > 0 {
                    infoRow(label: "子代理", value: "\(subagentCount) 个（随主任务切换）")
                } else if task.threadSource == "subagent" {
                    infoRow(label: "关系", value: "未找到主任务")
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var riskCard: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: riskIcon)
                .foregroundStyle(riskColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(riskTitle)
                    .font(.callout.weight(.semibold))
                Text(model.preflight.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.preflight.compactedEvents > 0 {
                    Text("历史压缩 \(model.preflight.compactedEvents) 次")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(riskColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(riskColor.opacity(0.2), lineWidth: 1)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(statusSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Divider()
                .frame(height: 13)
            Text(appVersionLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private var statusSummary: String {
        if page == .tasks {
            var parts = ["\(model.filteredTasks.count) / \(model.topLevelTasks.count) 个主任务"]
            if model.importantTaskCount > 0 { parts.append("\(model.importantTaskCount) 个重要") }
            if model.inProgressTaskCount > 0 { parts.append("\(model.inProgressTaskCount) 个进行中") }
            if model.linkedSubagentCount > 0 { parts.append("\(model.linkedSubagentCount) 个子代理") }
            if model.hiddenInternalApprovalReviewCount > 0 { parts.append("已隐藏 \(model.hiddenInternalApprovalReviewCount) 个内部审查") }
            return parts.joined(separator: " · ")
        }
        var parts = [
            "\(model.mindMapTasks.count) 个会话",
            "\(model.boardTreeCount) 棵树",
            "\(model.conversationRelationshipCount) 条关系"
        ]
        if model.boardAnnotationCount > 0 { parts.append("\(model.boardAnnotationCount) 个说明") }
        if model.showArchived { parts.append("包含归档") }
        return parts.joined(separator: " · ")
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }

    private func providerBadge(_ provider: String) -> some View {
        Text(ProviderOption.displayName(for: provider))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(provider == "openai" ? Color.blue : Color.purple)
            .background(
                (provider == "openai" ? Color.blue : Color.purple).opacity(0.1),
                in: Capsule()
            )
    }

    private func switchButtonTitle(task: CodexTask) -> String {
        if model.selectedRootTaskCount > 1 {
            return "批量切换 \(model.selectedRootTaskCount) 个会话到 \(ProviderOption.displayName(for: model.targetProviderID))"
        }
        if task.provider == model.targetProviderID {
            if model.preflight.compatibilityFixes > 0 {
                return "修复官方兼容性"
            }
            return "已经是该提供商"
        }
        return "切换到 \(ProviderOption.displayName(for: model.targetProviderID))"
    }

    private func forkButtonTitle(task: CodexTask) -> String {
        if model.selectedRootTaskCount > 1 {
            return "批量选择时不可新建分支"
        }
        if task.provider == model.targetProviderID {
            return "新建分支（保持 \(ProviderOption.displayName(for: model.targetProviderID))）"
        }
        return "新建分支并切换到 \(ProviderOption.displayName(for: model.targetProviderID))"
    }

    private var riskIcon: String {
        switch model.preflight.level {
        case .safe:
            return "checkmark.circle.fill"
        case .alreadyTarget:
            return "checkmark.seal.fill"
        case .blockedIncompatible:
            return "link.badge.plus"
        case .blockedRisk:
            return "exclamationmark.triangle.fill"
        case .blockedUnknown:
            return "questionmark.circle.fill"
        }
    }

    private var riskColor: Color {
        switch model.preflight.level {
        case .safe, .alreadyTarget:
            return .green
        case .blockedIncompatible:
            return .red
        case .blockedRisk:
            return .orange
        case .blockedUnknown:
            return .secondary
        }
    }

    private var riskTitle: String {
        if model.preflight.compatibilityFixes > 0 {
            return "可修复官方兼容性"
        }
        switch model.preflight.level {
        case .safe:
            return "上下文风险较低"
        case .alreadyTarget:
            return "无需切换"
        case .blockedIncompatible:
            return "需要配对接续会话"
        case .blockedRisk:
            return "需要确认风险"
        case .blockedUnknown:
            return "等待风险检查"
        }
    }
}

private enum WorkspacePage: String, CaseIterable, Identifiable {
    case tasks
    case mindMap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: return "任务列表"
        case .mindMap: return "思维画板"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: return "list.bullet.rectangle"
        case .mindMap: return "point.3.connected.trianglepath.dotted"
        }
    }
}
