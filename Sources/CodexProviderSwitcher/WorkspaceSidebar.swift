import SwiftUI

struct WorkspaceSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingEditor: WorkspaceEditor?
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("工作区", systemImage: "square.grid.2x2")
                    .font(.headline)
                Spacer()
                Menu {
                    if let workspace = model.selectedWorkspace {
                        Button("新建子分区", systemImage: "folder.badge.plus") {
                            begin(.newWorkspace(parentID: workspace.id), name: "新分区")
                        }
                        Button("新建画板", systemImage: "rectangle.on.rectangle") {
                            begin(.newTree(workspaceID: workspace.id), name: "新画板")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.selectedWorkspace == nil)
                .help("在当前工作区中新建子分区或画板")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    scopeRow(
                        id: WorkspaceScope.all,
                        title: "所有会话",
                        systemImage: "bubble.left.and.bubble.right",
                        count: model.topLevelTasks.count
                    )
                    scopeRow(
                        id: WorkspaceScope.unassigned,
                        title: "未分配",
                        systemImage: "tray",
                        count: model.unassignedTaskCount
                    )

                    Text("分区")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 3)

                    ForEach(model.rootWorkspaces) { workspace in
                        WorkspaceBranchView(
                            workspace: workspace,
                            onRename: { target in
                                begin(.renameWorkspace(workspaceID: target.id), name: target.name)
                            },
                            onNewChild: { target in
                                begin(.newWorkspace(parentID: target.id), name: "新分区")
                            },
                            onNewTree: { target in
                                begin(.newTree(workspaceID: target.id), name: "新画板")
                            }
                        )
                    }
                }
                .padding(8)
            }

            Divider()

            HStack(spacing: 8) {
                if let workspace = model.selectedWorkspace {
                    Button {
                        begin(.newWorkspace(parentID: workspace.id), name: "新分区")
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("在当前工作区中新建子分区")

                    Button {
                        begin(.newTree(workspaceID: workspace.id), name: "新画板")
                    } label: {
                        Image(systemName: "rectangle.on.rectangle")
                    }
                    .help("在当前工作区中新建画板")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .alert(editorTitle, isPresented: editorPresented) {
            TextField("名称", text: $draftName)
            Button("取消", role: .cancel) {
                pendingEditor = nil
            }
            Button(editorActionTitle) {
                commitEditor()
            }
        }
    }

    private func scopeRow(id: String, title: String, systemImage: String, count: Int) -> some View {
        Button {
            model.selectWorkspaceScope(id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background(
                model.selectedWorkspaceScopeID == id ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private var editorPresented: Binding<Bool> {
        Binding(
            get: { pendingEditor != nil },
            set: { if !$0 { pendingEditor = nil } }
        )
    }

    private var editorTitle: String {
        switch pendingEditor {
        case .newWorkspace: return "新建分区"
        case .renameWorkspace: return "重命名工作区"
        case .newTree: return "新建画板"
        case nil: return "编辑"
        }
    }

    private var editorActionTitle: String {
        switch pendingEditor {
        case .renameWorkspace: return "保存"
        default: return "创建"
        }
    }

    private func begin(_ editor: WorkspaceEditor, name: String) {
        draftName = name
        pendingEditor = editor
    }

    private func commitEditor() {
        guard let pendingEditor else { return }
        switch pendingEditor {
        case .newWorkspace(let parentID):
            _ = model.addWorkspace(name: draftName, parentID: parentID)
        case .renameWorkspace(let workspaceID):
            model.renameWorkspace(workspaceID, name: draftName)
        case .newTree(let workspaceID):
            _ = model.addTree(name: draftName, workspaceID: workspaceID)
        }
        self.pendingEditor = nil
    }
}

private struct WorkspaceBranchView: View {
    @EnvironmentObject private var model: AppModel
    let workspace: ConversationWorkspace
    let onRename: (ConversationWorkspace) -> Void
    let onNewChild: (ConversationWorkspace) -> Void
    let onNewTree: (ConversationWorkspace) -> Void

    @State private var expanded = true

    private var children: [ConversationWorkspace] {
        model.childWorkspaces(of: workspace.id)
    }

    var body: some View {
        if children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { child in
                    WorkspaceBranchView(
                        workspace: child,
                        onRename: onRename,
                        onNewChild: onNewChild,
                        onNewTree: onNewTree
                    )
                    .padding(.leading, 12)
                }
            } label: {
                row
            }
            .disclosureGroupStyle(.automatic)
        }
    }

    private var row: some View {
        Button {
            model.selectWorkspaceScope(workspace.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name)
                        .lineLimit(1)
                    if let sourcePath = workspace.sourcePath {
                        Text(sourcePath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text("\(model.taskCount(in: workspace.id))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: workspace.sourcePath == nil ? 32 : 44)
            .contentShape(Rectangle())
            .background(
                model.selectedWorkspaceScopeID == workspace.id
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help(workspace.sourcePath ?? workspace.name)
        .contextMenu {
            if !workspace.isSessionWorkspace {
                Button("重命名", systemImage: "pencil") { onRename(workspace) }
            }
            Button("新建子分区", systemImage: "folder.badge.plus") { onNewChild(workspace) }
            Button("新建画板", systemImage: "rectangle.on.rectangle") { onNewTree(workspace) }
        }
    }
}

private enum WorkspaceEditor {
    case newWorkspace(parentID: String?)
    case renameWorkspace(workspaceID: String)
    case newTree(workspaceID: String)
}
