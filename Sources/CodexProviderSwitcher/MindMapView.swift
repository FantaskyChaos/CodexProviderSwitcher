import SwiftUI

struct MindMapView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tool = BoardCanvasTool.select
    @State private var selection: Set<BoardSelection> = []
    @State private var librarySelection: Set<String> = []
    @State private var rightPanel = BoardRightPanel.library
    @State private var fitRequest = 0
    @State private var canvasZoom = 1.0
    @State private var showNewBoardPrompt = false
    @State private var showRenameBoardPrompt = false
    @State private var boardNameDraft = ""
    @State private var inspectorTitle = ""
    @State private var inspectorBody = ""

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                VStack(spacing: 0) {
                    boardToolbar
                        .frame(height: 42)
                        .zIndex(1)
                    Divider()
                        .zIndex(1)
                    GeometryReader { canvasGeometry in
                        boardCanvas
                            .frame(width: canvasGeometry.size.width, height: canvasGeometry.size.height)
                    }
                    .frame(minHeight: 0)
                    .clipped()
                    .zIndex(0)
                }
                .frame(minWidth: 650, maxHeight: .infinity, alignment: .topLeading)

                rightSidebar
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 390)
                    .frame(height: geometry.size.height, alignment: .top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minHeight: 0)
        .onChange(of: model.selectedBoardID) { _, _ in
            selection = []
            librarySelection = []
            canvasZoom = model.selectedBoard?.viewport.zoom ?? 1
            loadInspectorDrafts()
        }
        .onAppear {
            canvasZoom = model.selectedBoard?.viewport.zoom ?? 1
        }
        .onChange(of: selection) { _, _ in loadInspectorDrafts() }
        .alert("新建画板", isPresented: $showNewBoardPrompt) {
            TextField("画板名称", text: $boardNameDraft)
            Button("取消", role: .cancel) {}
            Button("创建") { _ = model.addTree(name: boardNameDraft) }
        }
        .alert("重命名画板", isPresented: $showRenameBoardPrompt) {
            TextField("画板名称", text: $boardNameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                guard let id = model.selectedBoardID else { return }
                model.renameTree(id, name: boardNameDraft)
            }
        }
    }

    private var boardToolbar: some View {
        HStack(spacing: 8) {
            if let workspace = model.selectedWorkspace {
                Label(workspace.name, systemImage: "folder")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Picker("画板", selection: boardSelection) {
                    ForEach(model.boardsForSelectedWorkspace) { board in Text(board.name).tag(board.id) }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 190)
                Button { boardNameDraft = "新画板"; showNewBoardPrompt = true } label: { Image(systemName: "plus") }
                    .help("新建画板")
                if let board = model.selectedBoard {
                    Button { boardNameDraft = board.name; showRenameBoardPrompt = true } label: { Image(systemName: "pencil") }
                        .help("重命名画板")
                }
            }

            Divider().frame(height: 20)
            Picker("工具", selection: $tool) {
                ForEach(BoardCanvasTool.allCases) { item in Image(systemName: item.systemImage).tag(item) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190).help(tool.title)
            Button { model.undoBoard() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndoBoard).help("撤销")
            Button { model.redoBoard() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedoBoard).help("重做")
            Picker("树方向", selection: boardLayoutSelection) {
                Image(systemName: "arrow.right").tag(ConversationTreeLayoutPreset.horizontal)
                Image(systemName: "arrow.down").tag(ConversationTreeLayoutPreset.vertical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 64)
            .help("横向或纵向整理整个画板")
            if let board = model.selectedBoard {
                Toggle(isOn: Binding(
                    get: { board.gridEnabled },
                    set: { model.setBoardGridEnabled($0) }
                )) {
                    Image(systemName: "grid")
                }
                .toggleStyle(.button)
                .help(board.gridEnabled ? "关闭网格吸附" : "开启网格吸附")
                Menu {
                    Button { model.snapCurrentBoardToGrid() } label: {
                        Label("全部吸附到网格", systemImage: "square.grid.3x3")
                    }
                    Button {
                        if let rootID = selectedRootID {
                            model.applyLayout(toRoot: rootID, preset: currentLayoutPreset)
                        } else {
                            model.applyCurrentTreeLayout(currentLayoutPreset)
                        }
                    } label: {
                        Label("整理当前树", systemImage: "arrow.triangle.branch")
                    }
                    Button { model.applyWholeBoardLayout() } label: {
                        Label("整理整个画板", systemImage: "wand.and.stars")
                    }
                    Divider()
                    Button { model.autoOrganizeAllConversations(); rightPanel = .candidates } label: {
                        Label("自动整理全部会话", systemImage: "rectangle.3.group")
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .help("网格与自动整理")
            }
            Menu {
                alignmentButtons
            } label: { Image(systemName: "align.horizontal.left") }
            .help("布局与对齐")
            Spacer()
            Button { canvasZoom = max(0.6, canvasZoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("缩小")
            Slider(value: $canvasZoom, in: 0.6...1.6, step: 0.05)
                .labelsHidden()
                .frame(width: 72)
                .help("画布缩放")
            Button { canvasZoom = 1 } label: {
                Text("\(Int((canvasZoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 42)
            }
            .help("恢复 100%")
            Button { canvasZoom = min(1.6, canvasZoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("放大")
            Button { fitRequest += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("适应画板内容")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.32))
    }

    @ViewBuilder private var alignmentButtons: some View {
        Button("左对齐") { model.alignBoardSelections(selection, alignment: .left) }
        Button("水平居中") { model.alignBoardSelections(selection, alignment: .center) }
        Button("右对齐") { model.alignBoardSelections(selection, alignment: .right) }
        Button("顶部对齐") { model.alignBoardSelections(selection, alignment: .top) }
        Button("垂直居中") { model.alignBoardSelections(selection, alignment: .middle) }
        Button("底部对齐") { model.alignBoardSelections(selection, alignment: .bottom) }
        Divider()
        Button("水平平均分布") { model.alignBoardSelections(selection, alignment: .distributeHorizontal) }
        Button("垂直平均分布") { model.alignBoardSelections(selection, alignment: .distributeVertical) }
    }

    private var boardSelection: Binding<String> {
        Binding(get: { model.selectedBoardID ?? "" }, set: { model.selectBoard($0) })
    }

    private var boardLayoutSelection: Binding<ConversationTreeLayoutPreset> {
        Binding(
            get: {
                let preset = model.selectedBoard?.layoutPreset ?? .horizontal
                return preset == .freeform ? .horizontal : preset
            },
            set: { model.applyCurrentTreeLayout($0) }
        )
    }

    private var currentLayoutPreset: ConversationTreeLayoutPreset {
        let preset = model.selectedBoard?.layoutPreset ?? .horizontal
        return preset == .freeform ? .horizontal : preset
    }

    private var selectedRootID: String? {
        guard let board = model.selectedBoard else { return nil }
        if let treeID = selection.compactMap({
            if case .tree(let id) = $0 { return id }
            return nil
        }).first {
            return treeID
        }
        if let nodeID = selection.compactMap({
            if case .node(let id) = $0 { return id }
            return nil
        }).first, board.nodes[nodeID] != nil {
            return BoardGraph.root(of: nodeID, parentByTaskID: board.parentByTaskID)
        }
        return nil
    }

    @ViewBuilder private var boardCanvas: some View {
        if let board = model.selectedBoard {
            BoardCanvasRepresentable(
                board: board,
                tasks: Dictionary(uniqueKeysWithValues: model.mindMapTasks.map { ($0.id, $0) }),
                importantIDs: Set(model.mindMapTasks.filter(model.isImportant).map(\.id)),
                inProgressIDs: Set(model.mindMapTasks.filter(model.isInProgress).map(\.id)),
                tool: tool,
                selection: selection,
                fitRequest: fitRequest,
                zoomLevel: canvasZoom,
                onSelection: {
                    selection = $0
                    syncSelectedTask()
                    if !$0.isEmpty { rightPanel = .inspector }
                },
                onMove: { model.moveBoardObjects($0, by: $1) },
                onResizeAnnotation: { model.resizeAnnotation($0, frame: $1) },
                onConnect: requestConnection,
                canConnect: model.canSetConversationParent,
                onAddAnnotation: { kind, point in
                    if let id = model.addAnnotation(kind: kind, at: point) {
                        selection = [.annotation(id)]; rightPanel = .inspector; tool = .select
                    }
                },
                onDropTasks: { ids, point in
                    selection = Set(model.assignConversationsToCurrentBoard(taskIDs: ids, at: point).map(BoardSelection.node))
                },
                onDelete: { model.removeBoardSelections($0); selection = [] },
                onOpen: { id in if let task = model.task(for: id) { model.openInCodex(task) } },
                onEdit: { item in selection = [item]; rightPanel = .inspector },
                onEditEdgeTitle: { childID, title in
                    let note = model.selectedBoard?.edges[childID]?.note ?? ""
                    model.updateEdge(childID: childID, title: title, note: note)
                },
                onMoveEdgeLabel: { childID, offset in
                    let edge = model.selectedBoard?.edges[childID] ?? ConversationEdgeMetadata()
                    model.updateEdge(childID: childID, title: edge.title, note: edge.note, labelOffset: offset)
                },
                onUndo: model.undoBoard,
                onRedo: model.redoBoard,
                onZoomChanged: { canvasZoom = $0 },
                onViewport: model.updateBoardViewport
            )
        } else {
            ContentUnavailableView {
                Label("当前工作区还没有画板", systemImage: "rectangle.on.rectangle")
            } actions: {
                Button("新建画板") { boardNameDraft = "新画板"; showNewBoardPrompt = true }
            }
        }
    }

    private var rightSidebar: some View {
        VStack(spacing: 0) {
            Picker("右侧面板", selection: $rightPanel) {
                ForEach(BoardRightPanel.allCases) { panel in Label(panel.title, systemImage: panel.systemImage).tag(panel) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            switch rightPanel {
            case .library: conversationLibrary
            case .outline: boardOutline
            case .inspector: boardInspector
            case .candidates: relationshipCandidates
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var conversationLibrary: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索待分配会话", text: $model.mapSearchText).textFieldStyle(.plain)
                Toggle("归档", isOn: $model.showArchived).toggleStyle(.checkbox).font(.caption)
            }
            .padding(10).background(.quaternary.opacity(0.25))
            List(model.mindMapLibraryTasks, selection: $librarySelection) { task in
                LibraryBoardRow(task: task, selected: librarySelection.contains(task.id))
                    .tag(task.id)
                    .onDrag {
                        let ids = librarySelection.contains(task.id) ? librarySelection.sorted() : [task.id]
                        return NSItemProvider(object: ids.joined(separator: "\n") as NSString)
                    }
            }
            HStack {
                Text("已选 \(librarySelection.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    selection = Set(model.assignConversationsToCurrentBoard(taskIDs: librarySelection.sorted()).map(BoardSelection.node))
                    librarySelection = []
                } label: { Label("加入画板", systemImage: "plus.circle.fill") }
                .disabled(librarySelection.isEmpty)
            }.padding(10)
        }
    }

    private var boardOutline: some View {
        List {
            if let board = model.selectedBoard {
                ForEach(BoardGraph.roots(nodeIDs: Set(board.nodes.keys), parentByTaskID: board.parentByTaskID), id: \.self) { root in
                    let meta = board.roots[root] ?? ConversationTreeRootMetadata(name: model.title(for: root))
                    DisclosureGroup {
                        ForEach(outlineNodeIDs(root: root, board: board), id: \.self) { id in
                            Button {
                                selection = [.node(id)]; syncSelectedTask(); rightPanel = .inspector
                            } label: {
                                Label(model.title(for: id), systemImage: id == root ? "circle.circle.fill" : "bubble.left").lineLimit(1)
                            }.buttonStyle(.plain)
                        }
                    } label: {
                        Button { selection = [.tree(root)]; rightPanel = .inspector } label: {
                            HStack {
                                Text(meta.name).lineLimit(1); Spacer()
                                Text("\(BoardGraph.descendants(of: root, parentByTaskID: board.parentByTaskID).count)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if !board.annotations.isEmpty {
                    Section("说明") {
                        ForEach(board.annotations.values.sorted(by: { $0.title < $1.title })) { item in
                            Button { selection = [.annotation(item.id)]; rightPanel = .inspector } label: {
                                Label(item.title, systemImage: item.kind == .text ? "textformat" : "rectangle.dashed")
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var relationshipCandidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let board = model.selectedBoard, board.source == .automatic {
                Text("自动整理画板 · \(board.nodes.count) 个会话 · \(model.pendingRelationshipCandidates.count) 条待确认")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            HStack {
                Label("待确认关系", systemImage: "questionmark.circle")
                    .font(.headline)
                Spacer()
                Button {
                    model.acceptAllRelationshipCandidates()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.pendingRelationshipCandidates.isEmpty)
                .help("确认全部候选")
            }
            .padding(12)
            Divider()
            if model.pendingRelationshipCandidates.isEmpty {
                ContentUnavailableView("暂无待确认关系", systemImage: "checkmark.circle")
            } else {
                List(model.pendingRelationshipCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(model.title(for: candidate.parentID)) → \(model.title(for: candidate.childID))")
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                        Text("置信度 \(candidate.score)/3 · \(candidate.reasons.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        HStack {
                            Button {
                                model.acceptRelationshipCandidate(candidate.id)
                            } label: {
                                Label("确认", systemImage: "checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                model.rejectRelationshipCandidate(candidate.id)
                            } label: {
                                Label("拒绝", systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder private var boardInspector: some View {
        if selection.count > 1 {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("已选择 \(selection.count) 个对象", systemImage: "rectangle.on.rectangle.angled").font(.headline)
                    multiParentPicker
                    Divider()
                    alignmentGrid
                    Button(role: .destructive) {
                        model.removeBoardSelections(selection); selection = []
                    } label: { Label("从画板移除所选内容", systemImage: "trash") }
                }.padding(18)
            }
        } else if let item = selection.first {
            ScrollView { singleInspector(item).padding(18) }
        } else {
            ContentUnavailableView("请选择画板对象", systemImage: "cursorarrow.click")
        }
    }

    @ViewBuilder private func singleInspector(_ item: BoardSelection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            switch item {
            case .node(let id): nodeInspector(id)
            case .edge(let childID): edgeInspector(childID)
            case .annotation(let id): annotationInspector(id)
            case .tree(let rootID): treeInspector(rootID)
            }
        }
    }

    private func nodeInspector(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title(for: id)).font(.headline)
            Text(id).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            parentPicker(childID: id)
            HStack {
                Button { if let task = model.task(for: id) { model.openInCodex(task) } } label: { Image(systemName: "arrow.up.forward.app") }
                Button(role: .destructive) { model.removeBoardSelections([.node(id)]); selection = [] } label: { Image(systemName: "trash") }
            }.buttonStyle(.bordered)
        }
    }

    private func edgeInspector(_ childID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("上下级连线", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            TextField("连线标题", text: $inspectorTitle)
            Text("关系备注").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $inspectorBody).frame(minHeight: 120).overlay(Rectangle().stroke(.separator))
            Button("保存说明") { model.updateEdge(childID: childID, title: inspectorTitle, note: inspectorBody) }
                .buttonStyle(.borderedProminent)
            Button(role: .destructive) {
                model.removeBoardSelections([.edge(childID)]); selection = []
            } label: { Label("断开关系", systemImage: "link.badge.plus") }
        }
    }

    private func annotationInspector(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.selectedBoard?.annotations[id]?.kind == .group ? "说明分组" : "文本说明",
                  systemImage: model.selectedBoard?.annotations[id]?.kind == .group ? "rectangle.dashed" : "textformat").font(.headline)
            TextField("标题", text: $inspectorTitle)
            TextEditor(text: $inspectorBody).frame(minHeight: 140).overlay(Rectangle().stroke(.separator))
            Button("保存说明") { model.updateAnnotation(id: id, title: inspectorTitle, body: inspectorBody) }
                .buttonStyle(.borderedProminent)
            Button(role: .destructive) { model.removeBoardSelections([.annotation(id)]); selection = [] } label: {
                Label("移除说明", systemImage: "trash")
            }
        }
    }

    private func treeInspector(_ rootID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("命名树", systemImage: "tree").font(.headline)
            TextField("树名称", text: $inspectorTitle)
            TextEditor(text: $inspectorBody).frame(minHeight: 120).overlay(Rectangle().stroke(.separator))
            Button("保存树说明") { model.updateRoot(rootID: rootID, name: inspectorTitle, note: inspectorBody) }
                .buttonStyle(.borderedProminent)
            HStack {
                Button { model.applyLayout(toRoot: rootID, preset: .vertical) } label: { Image(systemName: "arrow.down") }.help("纵向整理当前树")
                Button { model.applyLayout(toRoot: rootID, preset: .horizontal) } label: { Image(systemName: "arrow.right") }.help("横向整理当前树")
                Button {
                    let current = model.selectedBoard?.roots[rootID]?.isCollapsed ?? false
                    model.updateRoot(rootID: rootID, name: inspectorTitle, note: inspectorBody, isCollapsed: !current)
                } label: { Image(systemName: "rectangle.compress.vertical") }.help("折叠或展开当前树")
            }.buttonStyle(.bordered)
        }
    }

    private func parentPicker(childID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("上级节点").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("上级节点", selection: Binding(
                get: { model.conversationParentID(for: childID) ?? "" },
                set: { value in value.isEmpty ? _ = model.setConversationParent(childID: childID, parentID: nil) : requestConnection(parentID: value, childID: childID) }
            )) {
                Text("无上级（独立树）").tag("")
                ForEach(model.mindMapTasks.filter { $0.id != childID }) { Text($0.displayTitle).tag($0.id) }
            }.labelsHidden().pickerStyle(.menu)
        }
    }

    private var multiParentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("批量设置上级").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Menu("选择上级节点") {
                ForEach(model.mindMapTasks) { task in
                    Button(task.displayTitle) {
                        let nodeIDs = Set(selection.compactMap { if case .node(let id) = $0 { id } else { nil } })
                        _ = model.setConversationParents(childIDs: nodeIDs.subtracting([task.id]), parentID: task.id)
                    }
                }
            }
        }
    }

    private var alignmentGrid: some View {
        HStack {
            ForEach([BoardAlignment.left, .center, .right, .top, .middle, .bottom], id: \.self) { align in
                Button { model.alignBoardSelections(selection, alignment: align) } label: { Image(systemName: alignmentIcon(align)) }
            }
        }.buttonStyle(.bordered)
    }

    private func alignmentIcon(_ alignment: BoardAlignment) -> String {
        switch alignment {
        case .left: return "align.horizontal.left"
        case .center: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .middle: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        case .distributeHorizontal: return "distribute.horizontal.center"
        case .distributeVertical: return "distribute.vertical.center"
        }
    }

    private func requestConnection(parentID: String, childID: String) {
        _ = model.setConversationParent(childID: childID, parentID: parentID)
    }

    private func syncSelectedTask() {
        if let id = selection.compactMap({ if case .node(let id) = $0 { id } else { nil } }).first { model.selectedTaskID = id }
    }

    private func loadInspectorDrafts() {
        guard let board = model.selectedBoard, selection.count == 1, let item = selection.first else {
            inspectorTitle = ""; inspectorBody = ""; return
        }
        switch item {
        case .edge(let id): inspectorTitle = board.edges[id]?.title ?? ""; inspectorBody = board.edges[id]?.note ?? ""
        case .annotation(let id): inspectorTitle = board.annotations[id]?.title ?? ""; inspectorBody = board.annotations[id]?.body ?? ""
        case .tree(let id): inspectorTitle = board.roots[id]?.name ?? model.title(for: id); inspectorBody = board.roots[id]?.note ?? ""
        case .node: inspectorTitle = ""; inspectorBody = ""
        }
    }

    private func outlineNodeIDs(root: String, board: ConversationBoard) -> [String] {
        BoardGraph.descendants(of: root, parentByTaskID: board.parentByTaskID).sorted { lhs, rhs in
            if lhs == root { return true }; if rhs == root { return false }
            return model.title(for: lhs).localizedStandardCompare(model.title(for: rhs)) == .orderedAscending
        }
    }
}

private struct LibraryBoardRow: View {
    let task: CodexTask
    let selected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Image(systemName: task.archived ? "archivebox.fill" : "bubble.left.fill")
                .foregroundStyle(task.provider == "openai" ? Color.blue : Color.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayTitle).font(.callout.weight(.medium)).lineLimit(2)
                Text(ProviderOption.displayName(for: task.provider) + (task.archived ? " · 已归档" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

private enum BoardRightPanel: String, CaseIterable, Identifiable {
    case library, outline, candidates, inspector
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "待分配"
        case .outline: return "画板大纲"
        case .candidates: return "待确认"
        case .inspector: return "检查器"
        }
    }
    var systemImage: String {
        switch self {
        case .library: return "tray"
        case .outline: return "list.bullet.indent"
        case .candidates: return "questionmark.circle"
        case .inspector: return "slider.horizontal.3"
        }
    }
}
