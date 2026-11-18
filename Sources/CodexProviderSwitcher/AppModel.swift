import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [CodexTask] = []
    @Published var providers: [ProviderOption] = []
    @Published var activeProvider = "openai"
    @Published private(set) var importantTaskIDs: Set<String>
    @Published private(set) var inProgressTaskIDs: Set<String>
    @Published private(set) var organization: ConversationOrganization
    @Published private(set) var selectedWorkspaceScopeID = WorkspaceScope.all
    @Published private(set) var selectedTreeID: String?
    @Published private(set) var selectedTaskIDs: Set<String> = []
    @Published var selectedTaskID: String? {
        didSet {
            guard !isApplyingTaskSelection else { return }
            selectedTaskIDs = selectedTaskID.map { Set([$0]) } ?? []
            refreshPreflight()
        }
    }
    @Published var targetProviderID = "openai" {
        didSet { refreshPreflight() }
    }
    @Published var searchText = ""
    @Published var mapSearchText = ""
    @Published var showArchived = true
    @Published var preflight = ContextPreflight.unavailable
    @Published var isBusy = false
    @Published var statusMessage = "正在读取本地任务…"
    @Published var showRiskAlert = false
    @Published var showOpaqueHistoryRiskAlert = false
    @Published var showForkRiskAlert = false
    @Published var showForkConfirmation = false
    @Published var showResultAlert = false
    @Published var resultAlertTitle = ""
    @Published var resultAlertMessage = ""
    @Published var showCurrentTaskAlert = false
    @Published var currentTaskAlertMessage = ""

    private let store: CodexStore
    private let forkClient: CodexForkClient
    private let preferences: UserDefaults
    private var preflightGeneration = 0
    private var isApplyingTaskSelection = false
    private var pendingCurrentTaskSwitch: (taskID: String, targetProvider: String)?
    private var boardUndoStacks: [String: [ConversationBoard]] = [:]
    private var boardRedoStacks: [String: [ConversationBoard]] = [:]

    init(
        store: CodexStore = CodexStore(),
        forkClient: CodexForkClient = CodexForkClient(),
        preferences: UserDefaults = .standard
    ) {
        self.store = store
        self.forkClient = forkClient
        self.preferences = preferences
        importantTaskIDs = TaskImportance.load(from: preferences)
        inProgressTaskIDs = TaskProgress.load(from: preferences)
        organization = ConversationOrganizationStore.load(
            from: preferences,
            legacyParentByTaskID: TaskRelationships.load(from: preferences)
        )
        selectedTreeID = organization.trees.first?.id
        refresh()
    }

    var selectedTask: CodexTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    var selectedRootTasks: [CodexTask] {
        let ids = selectedTaskIDs.isEmpty
            ? selectedTaskID.map { Set([$0]) } ?? []
            : selectedTaskIDs
        return topLevelTasks.filter { ids.contains($0.id) }
    }

    var selectedRootTaskCount: Int { selectedRootTasks.count }

    func setTaskSelection(_ selection: Set<String>) {
        isApplyingTaskSelection = true
        selectedTaskIDs = selection
        if let selectedTaskID, selection.contains(selectedTaskID) {
            self.selectedTaskID = selectedTaskID
        } else {
            self.selectedTaskID = filteredTasks.first(where: { selection.contains($0.id) })?.id
        }
        isApplyingTaskSelection = false
        refreshPreflight()
    }

    var topLevelTasks: [CodexTask] {
        TaskImportance.topLevelTasks(
            from: tasks,
            importantTaskIDs: importantTaskIDs
        )
    }

    var importantTaskCount: Int {
        topLevelTasks.lazy.filter(isImportant).count
    }

    func isImportant(_ task: CodexTask) -> Bool {
        importantTaskIDs.contains(task.id)
    }

    func toggleImportant(_ task: CodexTask) {
        if importantTaskIDs.contains(task.id) {
            importantTaskIDs.remove(task.id)
            statusMessage = "已取消重要标记"
        } else {
            importantTaskIDs.insert(task.id)
            statusMessage = "已标记为重要并置顶"
        }
        TaskImportance.save(importantTaskIDs, to: preferences)
    }

    var inProgressTaskCount: Int {
        topLevelTasks.lazy.filter(isInProgress).count
    }

    func isInProgress(_ task: CodexTask) -> Bool {
        inProgressTaskIDs.contains(task.id)
    }

    func toggleInProgress(_ task: CodexTask) {
        if inProgressTaskIDs.contains(task.id) {
            inProgressTaskIDs.remove(task.id)
            statusMessage = "已取消进行中标签"
        } else {
            inProgressTaskIDs.insert(task.id)
            statusMessage = "已标记为进行中"
        }
        TaskProgress.save(inProgressTaskIDs, to: preferences)
    }

    var linkedSubagentCount: Int {
        tasks.lazy.filter { !$0.isInternalApprovalReview }.count - topLevelTasks.count
    }

    var hiddenInternalApprovalReviewCount: Int {
        tasks.lazy.filter(\.isInternalApprovalReview).count
    }

    var workspaces: [ConversationWorkspace] {
        organization.workspaces
    }

    var rootWorkspaces: [ConversationWorkspace] {
        organization.workspaces
            .filter { $0.parentID == nil }
            .sorted { lhs, rhs in
                let lhsDate = workspaceLatestUpdate(lhs)
                let rhsDate = workspaceLatestUpdate(rhs)
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func childWorkspaces(of workspaceID: String) -> [ConversationWorkspace] {
        organization.workspaces.filter { $0.parentID == workspaceID }
    }

    var selectedWorkspace: ConversationWorkspace? {
        organization.workspaces.first { $0.id == selectedWorkspaceScopeID }
    }

    var treesForSelectedWorkspace: [ConversationTree] {
        guard selectedWorkspace != nil else { return [] }
        return organization.trees.filter { $0.workspaceID == selectedWorkspaceScopeID }
    }

    var boardsForSelectedWorkspace: [ConversationBoard] { treesForSelectedWorkspace }
    var selectedBoard: ConversationBoard? { selectedTree }
    var selectedBoardID: String? { selectedTreeID }

    var selectedTree: ConversationTree? {
        guard let selectedTreeID else { return nil }
        return organization.trees.first { $0.id == selectedTreeID }
    }

    var conversationParentByTaskID: [String: String] {
        selectedTree?.parentByTaskID ?? [:]
    }

    var conversationRelationshipCount: Int {
        selectedTree?.parentByTaskID.count ?? 0
    }

    var boardTreeCount: Int {
        guard let board = selectedBoard else { return 0 }
        return BoardGraph.roots(nodeIDs: Set(board.nodes.keys), parentByTaskID: board.parentByTaskID).count
    }

    var boardAnnotationCount: Int { selectedBoard?.annotations.count ?? 0 }

    var pendingRelationshipCandidates: [ConversationRelationshipCandidate] {
        selectedBoard?.relationshipCandidates.filter { $0.status == .pending } ?? []
    }

    var organizableTasks: [CodexTask] {
        tasks.filter { !$0.isInternalApprovalReview }
    }

    var mindMapTasks: [CodexTask] {
        guard let selectedTree else { return [] }
        let nodeIDs = Set(selectedTree.nodes.keys)
        return organizableTasks.filter { nodeIDs.contains($0.id) && (showArchived || !$0.archived) }
    }

    var mindMapLibraryTasks: [CodexTask] {
        let assignedIDs = Set(selectedTree?.nodes.keys ?? Dictionary<String, ConversationTreeNode>().keys)
        let query = mapSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return organizableTasks.filter { task in
            guard !assignedIDs.contains(task.id) else { return false }
            guard taskBelongsToSelectedWorkspaceSource(task) else { return false }
            guard showArchived || !task.archived else { return false }
            return query.isEmpty || matches(task, query: query)
        }
    }

    var globallyAssignedTaskIDs: Set<String> {
        organization.trees.reduce(into: Set<String>()) { result, tree in
            result.formUnion(tree.nodes.keys)
        }
    }

    var unassignedTaskCount: Int {
        organizableTasks.lazy.filter { !self.globallyAssignedTaskIDs.contains($0.id) }.count
    }

    func taskCount(in workspaceID: String) -> Int {
        if let workspace = organization.workspaces.first(where: { $0.id == workspaceID }),
           let sourcePath = workspace.sourcePath {
            return organizableTasks.lazy.filter { $0.workspacePath == sourcePath }.count
        }
        let workspaceIDs = workspaceDescendantIDs(including: workspaceID)
        let taskIDs = organization.trees
            .filter { workspaceIDs.contains($0.workspaceID) }
            .reduce(into: Set<String>()) { $0.formUnion($1.nodes.keys) }
        return taskIDs.count
    }

    func selectWorkspaceScope(_ scopeID: String) {
        selectedWorkspaceScopeID = scopeID
        if organization.workspaces.contains(where: { $0.id == scopeID }) {
            selectedTreeID = organization.trees.first(where: { $0.workspaceID == scopeID })?.id
        }
    }

    func prepareMindMapSelection() {
        if selectedWorkspace == nil {
            let selectedPath = selectedTask?.workspacePath
            let workspaceID = organization.workspaces.first(where: { $0.sourcePath == selectedPath })?.id
                ?? rootWorkspaces.first(where: \.isSessionWorkspace)?.id
            if let workspaceID {
                selectWorkspaceScope(workspaceID)
            }
        } else if selectedTree == nil {
            selectedTreeID = treesForSelectedWorkspace.first?.id
        }
    }

    func selectTree(_ treeID: String) {
        guard organization.trees.contains(where: {
            $0.id == treeID && $0.workspaceID == selectedWorkspaceScopeID
        }) else { return }
        selectedTreeID = treeID
    }

    func selectBoard(_ boardID: String) { selectTree(boardID) }

    @discardableResult
    func addWorkspace(name: String, parentID: String?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString.lowercased()
        let validParent = organization.workspaces.contains(where: { $0.id == parentID })
            ? parentID
            : nil
        organization.workspaces.append(
            ConversationWorkspace(
                id: id,
                name: trimmed.isEmpty ? "新工作区" : trimmed,
                parentID: validParent,
                sourcePath: nil
            )
        )
        persistOrganization()
        selectWorkspaceScope(id)
        statusMessage = "已创建工作区"
        return id
    }

    func renameWorkspace(_ workspaceID: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = organization.workspaces.firstIndex(where: {
                $0.id == workspaceID && !$0.isSessionWorkspace
              }) else {
            return
        }
        organization.workspaces[index].name = trimmed
        persistOrganization()
        statusMessage = "已重命名工作区"
    }

    @discardableResult
    func addTree(name: String, workspaceID: String? = nil) -> String? {
        let targetWorkspaceID = workspaceID ?? selectedWorkspace?.id
        guard let targetWorkspaceID,
              organization.workspaces.contains(where: { $0.id == targetWorkspaceID }) else {
            statusMessage = "请先选择一个工作区"
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = ConversationTree(
            id: UUID().uuidString.lowercased(),
            workspaceID: targetWorkspaceID,
            name: trimmed.isEmpty ? "新画板" : trimmed,
            layoutPreset: .horizontal,
            nodes: [:],
            parentByTaskID: [:]
        )
        organization.trees.append(tree)
        persistOrganization()
        selectedTreeID = tree.id
        statusMessage = "已创建画板"
        return tree.id
    }

    func renameTree(_ treeID: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = organization.trees.firstIndex(where: { $0.id == treeID }) else {
            return
        }
        organization.trees[index].name = trimmed
        persistOrganization()
        statusMessage = "已重命名画板"
    }

    func nodePosition(for taskID: String) -> CGPoint? {
        guard let node = selectedTree?.nodes[taskID] else { return nil }
        return CGPoint(x: node.x, y: node.y)
    }

    func task(for id: String) -> CodexTask? {
        organizableTasks.first { $0.id == id }
    }

    func title(for taskID: String) -> String {
        task(for: taskID)?.displayTitle ?? taskID
    }

    var canUndoBoard: Bool {
        guard let id = selectedTreeID else { return false }
        return !(boardUndoStacks[id] ?? []).isEmpty
    }

    var canRedoBoard: Bool {
        guard let id = selectedTreeID else { return false }
        return !(boardRedoStacks[id] ?? []).isEmpty
    }

    func undoBoard() {
        guard let index = selectedTreeIndex,
              let boardID = selectedTreeID,
              var stack = boardUndoStacks[boardID],
              let previous = stack.popLast() else { return }
        boardUndoStacks[boardID] = stack
        boardRedoStacks[boardID, default: []].append(organization.trees[index])
        organization.trees[index] = previous
        persistOrganization()
        statusMessage = "已撤销画板操作"
    }

    func redoBoard() {
        guard let index = selectedTreeIndex,
              let boardID = selectedTreeID,
              var stack = boardRedoStacks[boardID],
              let next = stack.popLast() else { return }
        boardRedoStacks[boardID] = stack
        boardUndoStacks[boardID, default: []].append(organization.trees[index])
        organization.trees[index] = next
        persistOrganization()
        statusMessage = "已重做画板操作"
    }

    @discardableResult
    func assignConversationToCurrentTree(taskID: String, at position: CGPoint? = nil) -> Bool {
        guard let treeID = selectedTreeID,
              let index = organization.trees.firstIndex(where: { $0.id == treeID }),
              let task = organizableTasks.first(where: { $0.id == taskID }),
              taskBelongsToSelectedWorkspaceSource(task) else {
            statusMessage = "请先选择或创建一棵树"
            return false
        }
        let count = organization.trees[index].nodes.count
        let fallback = CGPoint(
            x: 135 + CGFloat(count % 4) * 185,
            y: 105 + CGFloat(count / 4) * 100
        )
        mutateBoard(at: index) { board in
            let requested = position ?? fallback
            let placed = board.gridEnabled
                ? ConversationGrid.snap(requested, spacingX: board.gridSpacingX, spacingY: board.gridSpacingY)
                : requested
            board.nodes[taskID] = ConversationTreeNode(x: Double(placed.x), y: Double(placed.y))
            board.parentByTaskID.removeValue(forKey: taskID)
            board.roots[taskID] = board.roots[taskID]
                ?? ConversationTreeRootMetadata(name: task.displayTitle)
        }
        selectedTaskID = taskID
        statusMessage = "已将会话加入当前画板"
        return true
    }

    @discardableResult
    func assignConversationsToCurrentBoard(taskIDs: [String], at origin: CGPoint? = nil) -> Set<String> {
        guard let index = selectedTreeIndex else { return [] }
        let valid = taskIDs.compactMap { id in
            organizableTasks.first(where: { $0.id == id && taskBelongsToSelectedWorkspaceSource($0) })
        }.filter { organization.trees[index].nodes[$0.id] == nil }
        guard !valid.isEmpty else { return [] }
        let base = origin ?? CGPoint(x: 150, y: 120)
        mutateBoard(at: index) { board in
            for (offset, task) in valid.enumerated() {
                let column = offset % 3
                let row = offset / 3
                let requested = CGPoint(
                    x: base.x + CGFloat(column) * CGFloat(board.gridSpacingX),
                    y: base.y + CGFloat(row) * CGFloat(board.gridSpacingY)
                )
                let placed = board.gridEnabled
                    ? ConversationGrid.snap(requested, spacingX: board.gridSpacingX, spacingY: board.gridSpacingY)
                    : requested
                board.nodes[task.id] = ConversationTreeNode(x: Double(placed.x), y: Double(placed.y))
                board.parentByTaskID.removeValue(forKey: task.id)
                board.roots[task.id] = ConversationTreeRootMetadata(name: task.displayTitle)
            }
        }
        selectedTaskID = valid.first?.id
        statusMessage = "已将 \(valid.count) 个会话加入当前画板"
        return Set(valid.map(\.id))
    }

    func moveConversationNode(taskID: String, to position: CGPoint) {
        moveBoardObjects([.node(taskID)], by: CGSize(
            width: position.x - (nodePosition(for: taskID)?.x ?? position.x),
            height: position.y - (nodePosition(for: taskID)?.y ?? position.y)
        ))
    }

    func moveBoardObjects(_ selections: Set<BoardSelection>, by delta: CGSize) {
        guard let index = selectedTreeIndex, delta != .zero else { return }
        let expanded = expandedSelections(selections, board: organization.trees[index])
        mutateBoard(at: index) { board in
            for selection in expanded {
                switch selection {
                case .node(let id):
                    guard var node = board.nodes[id] else { continue }
                    node.x += Double(delta.width)
                    node.y += Double(delta.height)
                    if board.gridEnabled {
                        let point = ConversationGrid.snap(
                            CGPoint(x: node.x, y: node.y),
                            spacingX: board.gridSpacingX,
                            spacingY: board.gridSpacingY
                        )
                        node.x = Double(point.x)
                        node.y = Double(point.y)
                    }
                    board.nodes[id] = node
                case .annotation(let id):
                    guard var annotation = board.annotations[id] else { continue }
                    annotation.x += Double(delta.width)
                    annotation.y += Double(delta.height)
                    if board.gridEnabled {
                        let point = ConversationGrid.snap(
                            CGPoint(x: annotation.x, y: annotation.y),
                            spacingX: board.gridSpacingX,
                            spacingY: board.gridSpacingY
                        )
                        annotation.x = Double(point.x)
                        annotation.y = Double(point.y)
                    }
                    board.annotations[id] = annotation
                case .edge, .tree:
                    break
                }
            }
            board.layoutPreset = .freeform
        }
    }

    func resizeAnnotation(_ id: String, frame: CGRect) {
        guard let index = selectedTreeIndex else { return }
        mutateBoard(at: index) { board in
            guard var item = board.annotations[id] else { return }
            let rawCenter = CGPoint(x: frame.midX, y: frame.midY)
            let center = board.gridEnabled
                ? ConversationGrid.snap(rawCenter, spacingX: board.gridSpacingX, spacingY: board.gridSpacingY)
                : rawCenter
            item.x = Double(center.x)
            item.y = Double(center.y)
            item.width = Double(max(120, frame.width))
            item.height = Double(max(70, frame.height))
            board.annotations[id] = item
        }
    }

    func removeConversationFromCurrentTree(_ taskID: String) {
        removeBoardSelections([.node(taskID)])
    }

    func removeBoardSelections(_ selections: Set<BoardSelection>) {
        guard let index = selectedTreeIndex, !selections.isEmpty else { return }
        mutateBoard(at: index) { board in
            let nodeIDs = Set(selections.compactMap { if case .node(let id) = $0 { id } else { nil } })
            let treeRoots = Set(selections.compactMap { if case .tree(let id) = $0 { id } else { nil } })
            let allNodes = nodeIDs.union(treeRoots.flatMap { BoardGraph.descendants(of: $0, parentByTaskID: board.parentByTaskID) })
            for id in allNodes {
                board.nodes.removeValue(forKey: id)
                board.parentByTaskID.removeValue(forKey: id)
                board.roots.removeValue(forKey: id)
                board.edges.removeValue(forKey: id)
            }
            for (child, parent) in board.parentByTaskID where allNodes.contains(parent) {
                board.parentByTaskID.removeValue(forKey: child)
                board.edges.removeValue(forKey: child)
            }
            for selection in selections {
                if case .edge(let childID) = selection {
                    board.parentByTaskID.removeValue(forKey: childID)
                    board.edges.removeValue(forKey: childID)
                }
                if case .annotation(let id) = selection { board.annotations.removeValue(forKey: id) }
            }
        }
        statusMessage = "已从当前画板移除所选内容"
    }

    func conversationParentID(for taskID: String) -> String? {
        selectedTree?.parentByTaskID[taskID]
    }

    func conversationChildren(of taskID: String) -> [CodexTask] {
        let childIDs = Set(
            (selectedTree?.parentByTaskID ?? [:]).compactMap { childID, parentID in
                parentID == taskID ? childID : nil
            }
        )
        return mindMapTasks.filter { childIDs.contains($0.id) }
    }

    @discardableResult
    func setConversationParent(childID: String, parentID: String?) -> Bool {
        guard let index = selectedTreeIndex,
              organization.trees[index].nodes[childID] != nil else { return false }
        if let parentID {
            guard organization.trees[index].nodes[parentID] != nil,
                  let updated = TaskRelationships.assigning(
                    childID: childID,
                    to: parentID,
                    in: organization.trees[index].parentByTaskID
                  ) else {
                statusMessage = "无法建立关系：上下级不能形成循环"
                return false
            }
            let oldRoot = BoardGraph.root(of: childID, parentByTaskID: organization.trees[index].parentByTaskID)
            let childRootMetadata = organization.trees[index].roots[oldRoot]
            mutateBoard(at: index) { board in
                board.parentByTaskID = updated
                if oldRoot == childID, let metadata = childRootMetadata {
                    board.edges[childID] = ConversationEdgeMetadata(title: metadata.name, note: metadata.note)
                    board.roots.removeValue(forKey: childID)
                }
            }
        } else {
            mutateBoard(at: index) { board in
                board.parentByTaskID.removeValue(forKey: childID)
                board.edges.removeValue(forKey: childID)
                board.roots[childID] = ConversationTreeRootMetadata(name: title(for: childID))
            }
        }
        selectedTaskID = childID
        statusMessage = parentID == nil ? "已设为根节点" : "已更新上下级关系"
        return true
    }

    func canSetConversationParent(parentID: String, childID: String) -> Bool {
        guard let board = selectedBoard,
              board.nodes[parentID] != nil,
              board.nodes[childID] != nil else { return false }
        return TaskRelationships.assigning(
            childID: childID,
            to: parentID,
            in: board.parentByTaskID
        ) != nil
    }

    @discardableResult
    func setConversationParents(childIDs: Set<String>, parentID: String) -> Bool {
        guard let index = selectedTreeIndex,
              organization.trees[index].nodes[parentID] != nil,
              !childIDs.isEmpty,
              !childIDs.contains(parentID) else { return false }
        var updated = organization.trees[index].parentByTaskID
        for childID in childIDs.sorted() {
            guard organization.trees[index].nodes[childID] != nil,
                  let next = TaskRelationships.assigning(childID: childID, to: parentID, in: updated) else {
                statusMessage = "批量挂接未执行：其中一个关系会形成循环"
                return false
            }
            updated = next
        }
        mutateBoard(at: index) { board in
            board.parentByTaskID = updated
            for childID in childIDs {
                let oldRoot = BoardGraph.root(of: childID, parentByTaskID: organization.trees[index].parentByTaskID)
                if oldRoot == childID, let metadata = board.roots.removeValue(forKey: childID) {
                    board.edges[childID] = ConversationEdgeMetadata(title: metadata.name, note: metadata.note)
                }
            }
        }
        statusMessage = "已批量更新 \(childIDs.count) 个节点的上级"
        return true
    }

    func updateEdge(childID: String, title: String, note: String, labelOffset: Double? = nil) {
        guard let index = selectedTreeIndex,
              organization.trees[index].parentByTaskID[childID] != nil else { return }
        mutateBoard(at: index) { board in
            var edge = board.edges[childID] ?? ConversationEdgeMetadata()
            edge.title = title
            edge.note = note
            if let labelOffset { edge.labelOffset = max(-0.35, min(0.35, labelOffset)) }
            board.edges[childID] = edge
        }
    }

    func updateRoot(rootID: String, name: String, note: String, isCollapsed: Bool? = nil) {
        guard let index = selectedTreeIndex else { return }
        mutateBoard(at: index) { board in
            var root = board.roots[rootID] ?? ConversationTreeRootMetadata(name: title(for: rootID))
            root.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title(for: rootID) : name
            root.note = note
            if let isCollapsed { root.isCollapsed = isCollapsed }
            board.roots[rootID] = root
        }
    }

    @discardableResult
    func addAnnotation(kind: BoardAnnotationKind, at point: CGPoint) -> String? {
        guard let index = selectedTreeIndex else { return nil }
        let id = UUID().uuidString.lowercased()
        let isGroup = kind == .group
        mutateBoard(at: index) { board in
            let placed = board.gridEnabled
                ? ConversationGrid.snap(point, spacingX: board.gridSpacingX, spacingY: board.gridSpacingY)
                : point
            board.annotations[id] = BoardAnnotation(
                id: id,
                kind: kind,
                x: Double(placed.x), y: Double(placed.y),
                width: isGroup ? 420 : 260,
                height: isGroup ? 240 : 120,
                title: isGroup ? "说明分组" : "说明",
                body: ""
            )
        }
        return id
    }

    func updateAnnotation(id: String, title: String, body: String) {
        guard let index = selectedTreeIndex else { return }
        mutateBoard(at: index) { board in
            guard var item = board.annotations[id] else { return }
            item.title = title
            item.body = body
            board.annotations[id] = item
        }
    }

    func alignBoardSelections(_ selections: Set<BoardSelection>, alignment: BoardAlignment) {
        guard let index = selectedTreeIndex else { return }
        let ids = selections.compactMap { if case .node(let id) = $0 { id } else { nil } }
        guard ids.count > 1 else { return }
        let positions = ids.compactMap { organization.trees[index].nodes[$0] }
        guard positions.count == ids.count else { return }
        mutateBoard(at: index) { board in
            switch alignment {
            case .left, .center, .right:
                let xs = positions.map(\.x)
                let target = alignment == .left ? xs.min()! : alignment == .right ? xs.max()! : xs.reduce(0,+) / Double(xs.count)
                for id in ids { board.nodes[id]?.x = target }
            case .top, .middle, .bottom:
                let ys = positions.map(\.y)
                let target = alignment == .top ? ys.min()! : alignment == .bottom ? ys.max()! : ys.reduce(0,+) / Double(ys.count)
                for id in ids { board.nodes[id]?.y = target }
            case .distributeHorizontal:
                let sorted = ids.sorted { board.nodes[$0]!.x < board.nodes[$1]!.x }
                let min = board.nodes[sorted.first!]!.x, max = board.nodes[sorted.last!]!.x
                for (i,id) in sorted.enumerated() { board.nodes[id]?.x = min + (max-min) * Double(i) / Double(sorted.count-1) }
            case .distributeVertical:
                let sorted = ids.sorted { board.nodes[$0]!.y < board.nodes[$1]!.y }
                let min = board.nodes[sorted.first!]!.y, max = board.nodes[sorted.last!]!.y
                for (i,id) in sorted.enumerated() { board.nodes[id]?.y = min + (max-min) * Double(i) / Double(sorted.count-1) }
            }
            if board.gridEnabled {
                for id in ids {
                    guard let node = board.nodes[id] else { continue }
                    let point = ConversationGrid.snap(
                        CGPoint(x: node.x, y: node.y),
                        spacingX: board.gridSpacingX,
                        spacingY: board.gridSpacingY
                    )
                    board.nodes[id] = ConversationTreeNode(x: Double(point.x), y: Double(point.y))
                }
            }
        }
    }

    func moveConversationToRoot(_ taskID: String) {
        _ = setConversationParent(childID: taskID, parentID: nil)
    }

    func applyCurrentTreeLayout(_ preset: ConversationTreeLayoutPreset) {
        guard let index = selectedTreeIndex else { return }
        mutateBoard(at: index) { board in
            board.layoutPreset = preset
            guard preset != .freeform else { return }
            for rootID in BoardGraph.roots(
                nodeIDs: Set(board.nodes.keys),
                parentByTaskID: board.parentByTaskID
            ) {
                var metadata = board.roots[rootID]
                    ?? ConversationTreeRootMetadata(name: title(for: rootID))
                metadata.layoutPreset = preset
                board.roots[rootID] = metadata
            }
            let positions = ConversationTreeAutoLayout.positions(
                taskIDs: board.nodes.keys.sorted { title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending },
                parentByTaskID: board.parentByTaskID,
                preset: preset,
                spacingX: board.gridSpacingX,
                spacingY: board.gridSpacingY
            )
            for (taskID, position) in positions {
                board.nodes[taskID] = ConversationTreeNode(
                    x: Double(position.x),
                    y: Double(position.y)
                )
            }
        }
        statusMessage = "已应用\(preset.displayName)"
    }

    func applyLayout(toRoot rootID: String, preset: ConversationTreeLayoutPreset) {
        guard let index = selectedTreeIndex else { return }
        let ids = BoardGraph.descendants(of: rootID, parentByTaskID: organization.trees[index].parentByTaskID)
        guard let anchor = organization.trees[index].nodes[rootID] else { return }
        mutateBoard(at: index) { board in
            let positions = ConversationTreeAutoLayout.positions(
                taskIDs: ids.sorted { title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending },
                parentByTaskID: board.parentByTaskID,
                preset: preset,
                spacingX: board.gridSpacingX,
                spacingY: board.gridSpacingY
            )
            guard let generatedRoot = positions[rootID] else { return }
            for (id, point) in positions {
                board.nodes[id] = ConversationTreeNode(
                    x: anchor.x + Double(point.x) - Double(generatedRoot.x),
                    y: anchor.y + Double(point.y) - Double(generatedRoot.y)
                )
            }
            var metadata = board.roots[rootID]
                ?? ConversationTreeRootMetadata(name: title(for: rootID))
            metadata.layoutPreset = preset
            board.roots[rootID] = metadata
        }
    }

    func updateBoardViewport(_ viewport: ConversationBoardViewport) {
        guard let index = selectedTreeIndex else { return }
        organization.trees[index].viewport = viewport
        persistOrganization()
    }

    func setBoardGridEnabled(_ enabled: Bool) {
        guard let index = selectedTreeIndex else { return }
        mutateBoard(at: index) { board in
            board.gridEnabled = enabled
        }
        statusMessage = enabled ? "已开启网格吸附" : "已关闭网格吸附"
    }

    func snapCurrentBoardToGrid() {
        guard let index = selectedTreeIndex else { return }
        mutateBoard(at: index) { board in
            for id in board.nodes.keys {
                guard let node = board.nodes[id] else { continue }
                let point = ConversationGrid.snap(
                    CGPoint(x: node.x, y: node.y),
                    spacingX: board.gridSpacingX,
                    spacingY: board.gridSpacingY
                )
                board.nodes[id] = ConversationTreeNode(x: Double(point.x), y: Double(point.y))
            }
            for id in board.annotations.keys {
                guard var annotation = board.annotations[id] else { continue }
                let point = ConversationGrid.snap(
                    CGPoint(x: annotation.x, y: annotation.y),
                    spacingX: board.gridSpacingX,
                    spacingY: board.gridSpacingY
                )
                annotation.x = Double(point.x)
                annotation.y = Double(point.y)
                board.annotations[id] = annotation
            }
            board.gridEnabled = true
        }
        statusMessage = "已将当前画板对象吸附到网格"
    }

    func applyWholeBoardLayout(_ preset: ConversationTreeLayoutPreset? = nil) {
        guard let board = selectedBoard else { return }
        applyCurrentTreeLayout(preset ?? (board.layoutPreset == .vertical ? .vertical : .horizontal))
        snapCurrentBoardToGrid()
        statusMessage = "已整理整个画板"
    }

    func acceptRelationshipCandidate(_ candidateID: String) {
        guard let index = selectedTreeIndex,
              let candidate = organization.trees[index].relationshipCandidates.first(where: { $0.id == candidateID }),
              candidate.status == .pending else { return }
        let oldRoot = BoardGraph.root(of: candidate.childID, parentByTaskID: organization.trees[index].parentByTaskID)
        guard let updatedParents = TaskRelationships.assigning(
            childID: candidate.childID,
            to: candidate.parentID,
            in: organization.trees[index].parentByTaskID
        ) else {
            statusMessage = "无法确认关系：会形成循环"
            return
        }
        mutateBoard(at: index) { board in
            board.parentByTaskID = updatedParents
            if oldRoot == candidate.childID, let metadata = board.roots.removeValue(forKey: candidate.childID) {
                board.edges[candidate.childID] = ConversationEdgeMetadata(title: metadata.name, note: metadata.note)
            }
            for offset in board.relationshipCandidates.indices where board.relationshipCandidates[offset].id == candidateID {
                board.relationshipCandidates[offset].status = .accepted
            }
        }
        statusMessage = "已确认候选关系"
    }

    func rejectRelationshipCandidate(_ candidateID: String) {
        guard let index = selectedTreeIndex else { return }
        mutateBoard(at: index) { board in
            for offset in board.relationshipCandidates.indices where board.relationshipCandidates[offset].id == candidateID {
                board.relationshipCandidates[offset].status = .rejected
            }
        }
        statusMessage = "已拒绝候选关系"
    }

    func acceptAllRelationshipCandidates() {
        let candidates = pendingRelationshipCandidates
        for candidate in candidates { acceptRelationshipCandidate(candidate.id) }
        statusMessage = "已尝试确认 \(candidates.count) 条候选关系"
    }

    func autoOrganizeAllConversations() {
        guard !isBusy else { return }
        let availableTasks = organizableTasks
        guard !availableTasks.isEmpty else {
            statusMessage = "没有可整理的会话"
            return
        }
        let currentOrganization = organization
        let preferences = self.preferences
        let selectedWorkspaceID = selectedWorkspaceScopeID
        isBusy = true
        statusMessage = "正在按工作区自动整理会话…"
        Task {
            let grouped = Dictionary(grouping: availableTasks, by: \.workspacePath)
            var updated = currentOrganization
            var firstBoardID: String?
            var boardCount = 0
            var nodeCount = 0
            var candidateCount = 0

            var workspacePaths = grouped.keys.sorted { lhs, rhs in
                let leftDate = grouped[lhs]?.map(\.updatedAt).max() ?? .distantPast
                let rightDate = grouped[rhs]?.map(\.updatedAt).max() ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs < rhs
            }
            if let emptyPath = workspacePaths.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                workspacePaths.removeAll { $0 == emptyPath }
                workspacePaths.append(emptyPath)
            }
            for path in workspacePaths {
                guard let group = grouped[path], !group.isEmpty else { continue }
                let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                let workspaceID = normalizedPath.isEmpty ? ConversationOrganization.defaultWorkspaceID : ConversationWorkspace.sessionID(for: path)
                let workspaceName = normalizedPath.isEmpty
                    ? "未指定工作区"
                    : updated.workspaces.first(where: { $0.id == workspaceID })?.name
                        ?? URL(fileURLWithPath: path).lastPathComponent
                let workspaceIndex: Int
                if let existingIndex = updated.workspaces.firstIndex(where: { $0.id == workspaceID }) {
                    workspaceIndex = existingIndex
                } else {
                    updated.workspaces.append(ConversationWorkspace(
                        id: workspaceID, name: workspaceName, parentID: nil, sourcePath: normalizedPath.isEmpty ? nil : path
                    ))
                    workspaceIndex = updated.workspaces.count - 1
                }
                let boardIndex: Int
                if let existing = updated.trees.firstIndex(where: {
                    $0.workspaceID == workspaceID && $0.source == .automatic
                }) {
                    boardIndex = existing
                } else {
                    updated.trees.append(
                        ConversationBoard(
                            id: UUID().uuidString.lowercased(),
                            workspaceID: workspaceID,
                            name: "自动整理 · \(workspaceName)",
                            layoutPreset: .horizontal,
                            nodes: [:],
                            parentByTaskID: [:],
                            gridEnabled: true,
                            source: .automatic
                        )
                    )
                    boardIndex = updated.trees.count - 1
                }
                var board = updated.trees[boardIndex]
                board.workspaceID = updated.workspaces[workspaceIndex].id
                board.name = "自动整理 · \(workspaceName)"
                board.layoutPreset = .horizontal
                board.gridEnabled = true
                let taskIDs = Set(group.map(\.id))
                board.nodes = Dictionary(uniqueKeysWithValues: group.map { task in
                    (task.id, ConversationTreeNode(x: 0, y: 0))
                })
                board.parentByTaskID = Dictionary(uniqueKeysWithValues: group.compactMap { task in
                    guard let parentID = task.parentThreadID, taskIDs.contains(parentID) else { return nil }
                    return (task.id, parentID)
                })
                board.roots = [:]
                board.edges = [:]
                for rootID in BoardGraph.roots(nodeIDs: taskIDs, parentByTaskID: board.parentByTaskID) {
                    board.roots[rootID] = ConversationTreeRootMetadata(name: title(for: rootID))
                }
                let positions = ConversationTreeAutoLayout.positions(
                    taskIDs: Array(taskIDs), parentByTaskID: board.parentByTaskID, preset: .horizontal
                )
                for (id, position) in positions {
                    let snapped = ConversationGrid.snap(position, spacingX: board.gridSpacingX, spacingY: board.gridSpacingY)
                    board.nodes[id] = ConversationTreeNode(x: Double(snapped.x), y: Double(snapped.y))
                }
                board.relationshipCandidates = ConversationAutoOrganizer.candidates(
                    tasks: group,
                    existing: board.relationshipCandidates
                ).filter { candidate in
                    board.parentByTaskID[candidate.childID] == nil
                }
                updated.trees[boardIndex] = BoardGraph.normalizedMetadata(board: board) { id in
                    group.first(where: { $0.id == id })?.displayTitle ?? id
                }
                firstBoardID = firstBoardID ?? board.id
                boardCount += 1
                nodeCount += group.count
                candidateCount += board.relationshipCandidates.filter { $0.status == .pending }.count
            }

            guard let data = try? JSONEncoder().encode(updated) else {
                isBusy = false
                statusMessage = "自动整理失败，未写入数据"
                return
            }
            preferences.set(data, forKey: ConversationOrganizationStore.defaultsKey)
            organization = updated
            if let firstBoardID {
                selectedWorkspaceScopeID = updated.trees.first(where: { $0.id == firstBoardID })?.workspaceID ?? selectedWorkspaceID
                selectedTreeID = firstBoardID
            }
            isBusy = false
            statusMessage = "已整理 \(nodeCount) 个会话，生成 \(boardCount) 个自动画板，待确认关系 \(candidateCount) 条"
        }
    }

    private var selectedTreeIndex: Int? {
        guard let selectedTreeID else { return nil }
        return organization.trees.firstIndex { $0.id == selectedTreeID }
    }

    private func mutateBoard(at index: Int, _ mutation: (inout ConversationBoard) -> Void) {
        let original = organization.trees[index]
        var updated = original
        mutation(&updated)
        updated = BoardGraph.normalizedMetadata(board: updated, title: title(for:))
        guard updated != original else { return }
        boardUndoStacks[original.id, default: []].append(original)
        if boardUndoStacks[original.id]!.count > 100 { boardUndoStacks[original.id]!.removeFirst() }
        boardRedoStacks[original.id] = []
        organization.trees[index] = updated
        persistOrganization()
    }

    private func expandedSelections(_ selections: Set<BoardSelection>, board: ConversationBoard) -> Set<BoardSelection> {
        var result = selections
        for selection in selections where {
            if case .tree = selection { return true }
            return false
        }() {
            if case .tree(let rootID) = selection {
                result.formUnion(BoardGraph.descendants(of: rootID, parentByTaskID: board.parentByTaskID).map(BoardSelection.node))
            }
        }
        return result
    }

    private func persistOrganization() {
        ConversationOrganizationStore.save(organization, to: preferences)
    }

    private func workspaceDescendantIDs(including workspaceID: String) -> Set<String> {
        var result: Set<String> = [workspaceID]
        var queue = [workspaceID]
        while let parentID = queue.first {
            queue.removeFirst()
            for child in childWorkspaces(of: parentID) where result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    private func sourcePath(for workspaceID: String) -> String? {
        var cursor: String? = workspaceID
        var visited: Set<String> = []
        while let currentID = cursor, visited.insert(currentID).inserted {
            guard let workspace = organization.workspaces.first(where: { $0.id == currentID }) else {
                return nil
            }
            if let sourcePath = workspace.sourcePath { return sourcePath }
            cursor = workspace.parentID
        }
        return nil
    }

    private func taskBelongsToSelectedWorkspaceSource(_ task: CodexTask) -> Bool {
        guard let sourcePath = sourcePath(for: selectedWorkspaceScopeID) else { return false }
        return task.workspacePath == sourcePath
    }

    private func workspaceLatestUpdate(_ workspace: ConversationWorkspace) -> Date {
        guard let sourcePath = workspace.sourcePath else { return .distantPast }
        return organizableTasks.lazy
            .filter { $0.workspacePath == sourcePath }
            .map(\.updatedAt)
            .max() ?? .distantPast
    }

    private func taskMatchesSelectedWorkspace(_ task: CodexTask) -> Bool {
        switch selectedWorkspaceScopeID {
        case WorkspaceScope.all:
            return true
        case WorkspaceScope.unassigned:
            return !globallyAssignedTaskIDs.contains(task.id)
        default:
            if let sourcePath = selectedWorkspace?.sourcePath {
                return task.workspacePath == sourcePath
            }
            let workspaceIDs = workspaceDescendantIDs(including: selectedWorkspaceScopeID)
            return organization.trees.contains {
                workspaceIDs.contains($0.workspaceID) && $0.nodes[task.id] != nil
            }
        }
    }

    var selectedSubagents: [CodexTask] {
        guard let selectedTask else { return [] }
        return descendants(of: selectedTask.id)
    }

    var selectedTaskGroup: [CodexTask] {
        var result: [CodexTask] = []
        var seen: Set<String> = []
        for root in selectedRootTasks {
            for task in [root] + descendants(of: root.id) where seen.insert(task.id).inserted {
                result.append(task)
            }
        }
        return result
    }

    var filteredTasks: [CodexTask] {
        topLevelTasks.filter { task in
            let archiveMatch = showArchived || !task.archived
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard archiveMatch, taskMatchesSelectedWorkspace(task) else { return false }
            guard !query.isEmpty else { return true }
            return matches(task, query: query)
                || descendants(of: task.id).contains { matches($0, query: query) }
        }
    }

    func descendants(of taskID: String) -> [CodexTask] {
        var result: [CodexTask] = []
        var queue = [taskID]
        var visited: Set<String> = [taskID]
        while !queue.isEmpty {
            let parentID = queue.removeFirst()
            let children = tasks.filter { $0.parentThreadID == parentID }
            for child in children where visited.insert(child.id).inserted {
                result.append(child)
                queue.append(child.id)
            }
        }
        return result
    }

    private func matches(_ task: CodexTask, query: String) -> Bool {
        task.displayTitle.localizedCaseInsensitiveContains(query)
                || task.title.localizedCaseInsensitiveContains(query)
                || task.preview.localizedCaseInsensitiveContains(query)
                || task.id.localizedCaseInsensitiveContains(query)
                || task.provider.localizedCaseInsensitiveContains(query)
                || (task.model?.localizedCaseInsensitiveContains(query) ?? false)
                || (isInProgress(task) && "进行中".localizedCaseInsensitiveContains(query))
    }

    var canSwitch: Bool {
        !isBusy && preflight.level != .blockedIncompatible && (
            selectedTaskGroup.contains { $0.provider != targetProviderID }
                || preflight.compatibilityFixes > 0
                || preflight.level == .blockedOpaqueHistory
        )
    }

    var canForkAndSwitch: Bool {
        !isBusy
            && selectedRootTaskCount == 1
            && selectedTask != nil
            && preflight.level != .blockedIncompatible
            && preflight.level != .blockedOpaqueHistory
    }

    func refresh() {
        isBusy = true
        statusMessage = "正在读取本地任务…"
        let store = self.store
        Task {
            do {
                let result = try await Task.detached {
                    (try store.loadTasks(), try store.loadProviderConfiguration())
                }.value
                tasks = result.0
                let configuredProviders = Dictionary(
                    uniqueKeysWithValues: result.1.providers.map { ($0.id, $0) }
                )
                let taskProviderIDs = Set(result.0.map(\.provider))
                providers = Set(configuredProviders.keys).union(taskProviderIDs)
                    .map { id in
                        configuredProviders[id]
                            ?? ProviderOption(id: id, displayName: ProviderOption.displayName(for: id))
                    }
                    .sorted {
                        if $0.id == result.1.activeProvider { return true }
                        if $1.id == result.1.activeProvider { return false }
                        if $0.id == "openai" { return true }
                        if $1.id == "openai" { return false }
                        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    }
                activeProvider = result.1.activeProvider
                targetProviderID = result.1.activeProvider
                synchronizeSessionWorkspaces()
                let validIDs = Set(organizableTasks.map(\.id))
                var normalizedOrganization = organization
                for index in normalizedOrganization.trees.indices {
                    normalizedOrganization.trees[index].nodes = normalizedOrganization.trees[index].nodes.filter {
                        validIDs.contains($0.key)
                    }
                    let nodeIDs = Set(normalizedOrganization.trees[index].nodes.keys)
                    normalizedOrganization.trees[index].parentByTaskID = TaskRelationships.pruned(
                        normalizedOrganization.trees[index].parentByTaskID,
                        validTaskIDs: nodeIDs
                    )
                }
                if normalizedOrganization != organization {
                    organization = normalizedOrganization
                    persistOrganization()
                }
                if selectedWorkspace == nil,
                   selectedWorkspaceScopeID != WorkspaceScope.all,
                   selectedWorkspaceScopeID != WorkspaceScope.unassigned {
                    selectedWorkspaceScopeID = WorkspaceScope.all
                }
                if let selectedTreeID,
                   !organization.trees.contains(where: { $0.id == selectedTreeID }) {
                    self.selectedTreeID = nil
                }
                if let currentID = selectedTaskID,
                   organizableTasks.contains(where: { $0.id == currentID }) {
                    selectedTaskID = currentID
                } else {
                    selectedTaskID = topLevelTasks.first?.id
                }
                let hiddenCount = hiddenInternalApprovalReviewCount
                statusMessage = hiddenCount > 0
                    ? "已读取 \(topLevelTasks.count) 个主任务，已隐藏 \(hiddenCount) 个内部审查任务"
                    : "已读取 \(topLevelTasks.count) 个主任务"
            } catch {
                presentError(error)
                statusMessage = "读取失败"
            }
            isBusy = false
        }
    }

    @discardableResult
    func switchCurrentCodexTask() -> Bool {
        let detection = CodexCurrentThreadDetector().detect(tasks: tasks)
        switch detection {
        case .found(let threadID):
            guard let task = topLevelTask(containing: threadID) else {
                showCurrentTaskDetectionError("Codex 当前会话不在可切换的主任务列表中。")
                return false
            }
            selectedWorkspaceScopeID = WorkspaceScope.all
            searchText = ""
            if task.archived { showArchived = true }
            selectedTaskID = task.id
            targetProviderID = activeProvider
            let targetName = ProviderOption.displayName(for: activeProvider)
            guard selectedTaskGroup.contains(where: { $0.provider != activeProvider }) else {
                resultAlertTitle = "需要重新加载 Codex"
                resultAlertMessage = """
                当前会话的磁盘记录已经是\(targetName)：\(task.displayTitle)

                Codex 运行中的会话可能仍保留切换前的提供商和端点。请选择“重启并打开 Codex”，让当前会话重新读取已保存的提供商；仅再次打开同一会话不能保证清除旧的内存状态。
                """
                statusMessage = "当前会话已是\(targetName)，等待重新加载 Codex"
                showResultAlert = true
                return true
            }
            pendingCurrentTaskSwitch = (task.id, activeProvider)
            statusMessage = "正在检查当前会话并准备切换到\(targetName)…"
            refreshPreflight()
            return true
        case .codexNotRunning:
            showCurrentTaskDetectionError("没有检测到正在运行的 Codex。请先在 Codex 中打开需要切换的会话。")
        case .accessibilityPermissionRequired:
            showCurrentTaskDetectionError("当前 App 还不能读取 Codex 顶部的会话标题。请确认“Codex 提供商切换”已在系统设置的辅助功能列表中开启，然后完全退出并重新打开本 App。\n\n本次不会自动打开系统设置，也不会影响 Codex。")
        case .noFocusedThread:
            showCurrentTaskDetectionError("没有在 Codex 顶部读到当前会话。请先点开一个已保存的会话，再回到这里重试。")
        case .ambiguousTitle(let title):
            showCurrentTaskDetectionError("有多个会话都叫“\(title)”，目前无法可靠区分。请先重命名其中一个会话，避免切错。")
        case .unavailableThread(let threadID):
            let detail = threadID.hasPrefix("client-new-thread:")
                ? "当前是尚未保存的新会话，请先在 Codex 中发送第一条消息。"
                : "当前会话不在本机任务数据库中，可能是云端会话或尚未同步。"
            showCurrentTaskDetectionError("\(detail)\n\n检测结果：\(threadID)")
        case .unavailableTitle(let title):
            showCurrentTaskDetectionError("Codex 当前打开的是“\(title)”，但本机任务数据库中没有对应会话。它可能是尚未保存的新会话、云端会话，或任务列表尚未刷新。")
        }
        return false
    }

    private func topLevelTask(containing taskID: String) -> CodexTask? {
        guard var task = tasks.first(where: { $0.id == taskID }) else { return nil }
        var visited: Set<String> = [task.id]
        while let parentID = task.parentThreadID,
              visited.insert(parentID).inserted,
              let parent = tasks.first(where: { $0.id == parentID }) {
            task = parent
        }
        return topLevelTasks.first(where: { $0.id == task.id })
    }

    private func showCurrentTaskDetectionError(_ message: String) {
        currentTaskAlertMessage = message
        showCurrentTaskAlert = true
        statusMessage = "未能读取当前会话"
    }

    private func synchronizeSessionWorkspaces() {
        let paths = Set(
            organizableTasks.map(\.workspacePath).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
        var updated = organization

        if let defaultTree = updated.trees.first(where: {
            $0.id == ConversationOrganization.defaultTreeID
        }), defaultTree.nodes.isEmpty {
            updated.trees.removeAll { $0.id == ConversationOrganization.defaultTreeID }
            let hasDefaultChildren = updated.workspaces.contains {
                $0.parentID == ConversationOrganization.defaultWorkspaceID
            }
            if !hasDefaultChildren {
                updated.workspaces.removeAll {
                    $0.id == ConversationOrganization.defaultWorkspaceID
                }
            }
        }

        for path in paths.sorted() {
            let workspaceID = ConversationWorkspace.sessionID(for: path)
            let displayName = URL(fileURLWithPath: path).lastPathComponent.isEmpty
                ? path
                : URL(fileURLWithPath: path).lastPathComponent
            if let index = updated.workspaces.firstIndex(where: { $0.id == workspaceID }) {
                updated.workspaces[index].name = displayName
                updated.workspaces[index].sourcePath = path
                updated.workspaces[index].parentID = nil
            } else {
                updated.workspaces.append(
                    ConversationWorkspace(
                        id: workspaceID,
                        name: displayName,
                        parentID: nil,
                        sourcePath: path
                    )
                )
            }
            if !updated.trees.contains(where: { $0.workspaceID == workspaceID }) {
                updated.trees.append(
                    ConversationTree(
                        id: UUID().uuidString.lowercased(),
                        workspaceID: workspaceID,
                        name: "主画板",
                        layoutPreset: .horizontal,
                        nodes: [:],
                        parentByTaskID: [:]
                    )
                )
            }
        }

        if updated != organization {
            organization = updated
            persistOrganization()
        }
    }

    func refreshPreflight() {
        preflightGeneration += 1
        let generation = preflightGeneration
        let group = selectedTaskGroup
        guard !group.isEmpty else {
            preflight = .unavailable
            return
        }
        let target = targetProviderID
        let store = self.store
        preflight = ContextPreflight(
            level: .blockedUnknown,
            latestInputTokens: nil,
            currentContextWindow: nil,
            targetContextWindow: nil,
            guardrailTokens: nil,
            headroomTokens: nil,
            compactedEvents: 0,
            message: "正在检查上下文风险…"
        )
        Task {
            let result = await Task.detached {
                Result { try store.preflight(tasks: group, targetProvider: target) }
            }.value
            guard generation == preflightGeneration else { return }
            switch result {
            case .success(let value):
                preflight = value
            case .failure(let error):
                preflight = ContextPreflight(
                    level: .blockedUnknown,
                    latestInputTokens: nil,
                    currentContextWindow: nil,
                    targetContextWindow: nil,
                    guardrailTokens: nil,
                    headroomTokens: nil,
                    compactedEvents: 0,
                    message: error.localizedDescription
                )
            }
            continuePendingCurrentTaskSwitchIfNeeded()
        }
    }

    private func continuePendingCurrentTaskSwitchIfNeeded() {
        guard let request = pendingCurrentTaskSwitch else { return }
        guard selectedTaskID == request.taskID,
              targetProviderID == request.targetProvider else {
            pendingCurrentTaskSwitch = nil
            return
        }
        pendingCurrentTaskSwitch = nil
        requestSwitch()
    }

    func requestSwitch() {
        guard selectedTask != nil else { return }
        if preflight.level == .blockedOpaqueHistory {
            showOpaqueHistoryRiskAlert = true
            return
        }
        if preflight.level == .blockedIncompatible {
            presentError(SwitcherError.unsafe(preflight.message))
            return
        }
        if preflight.level == .blockedRisk || preflight.level == .blockedUnknown {
            showRiskAlert = true
        } else {
            performSwitch(allowRisk: false)
        }
    }

    func forceSwitch() {
        guard preflight.level != .blockedIncompatible else {
            presentError(SwitcherError.unsafe(preflight.message))
            return
        }
        performSwitch(
            allowRisk: true,
            allowOpaqueHistory: preflight.level == .blockedOpaqueHistory
        )
    }

    func requestForkAndSwitch() {
        guard selectedTask != nil, selectedRootTaskCount == 1 else { return }
        if preflight.level == .blockedIncompatible || preflight.level == .blockedOpaqueHistory {
            presentError(SwitcherError.unsafe(preflight.message))
            return
        }
        if preflight.level == .blockedRisk || preflight.level == .blockedUnknown {
            showForkRiskAlert = true
        } else {
            showForkConfirmation = true
        }
    }

    func confirmForkAndSwitch() {
        performForkAndSwitch(allowRisk: false)
    }

    func forceForkAndSwitch() {
        guard preflight.level != .blockedIncompatible,
              preflight.level != .blockedOpaqueHistory else {
            presentError(SwitcherError.unsafe(preflight.message))
            return
        }
        performForkAndSwitch(allowRisk: true)
    }

    func openInCodex(_ task: CodexTask) {
        guard let url = CodexDeepLink.taskURL(threadID: task.id) else {
            presentError(SwitcherError.invalidData("任务 ID 无法生成 Codex 打开链接"))
            return
        }
        if NSWorkspace.shared.open(url) {
            statusMessage = "已通知 Codex 打开任务；运行中的旧提供商状态可能仍需重启"
        } else {
            presentError(SwitcherError.invalidData("无法打开 Codex；请确认 Codex 已安装"))
        }
    }

    func repairSelectedConversation() {
        guard !isBusy, selectedRootTaskCount == 1, let task = selectedTask else { return }
        isBusy = true
        statusMessage = "正在备份并修复会话历史…"
        let store = self.store
        Task {
            do {
                let result = try await Task.detached {
                    try store.switchTask(task: task, targetProvider: task.provider)
                }.value
                await reloadAfterSwitch(selecting: task.id)
                statusMessage = "已修复 \(result.compatibilityFixes) 条历史记录，正在重新加载 Codex…"
                try await CodexApplicationReloader.restartAndOpen(threadID: task.id) { [weak self] message in
                    self?.statusMessage = message
                }
                statusMessage = "会话历史已修复，请在 Codex 中继续；完整原历史已有备份"
            } catch {
                presentError(error)
                statusMessage = "修复或重新加载未完成：\(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    func restartCodexAndOpen(threadID: String) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在请求 Codex 重新加载…"
        Task {
            do {
                try await CodexApplicationReloader.restartAndOpen(threadID: threadID) { [weak self] message in
                    self?.statusMessage = message
                }
                statusMessage = "已请求 Codex 重新启动并打开任务"
            } catch {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                presentError(error)
                statusMessage = "任务已保存，但 Codex 重新加载未完成"
            }
            isBusy = false
        }
    }

    private func performSwitch(allowRisk: Bool, allowOpaqueHistory: Bool = false) {
        guard let task = selectedTask else { return }
        let group = selectedTaskGroup
        let target = targetProviderID
        let changesProvider = group.contains { $0.provider != target }
        let store = self.store
        isBusy = true
        statusMessage = "正在备份并切换…"
        Task {
            let result = await Task.detached {
                Result {
                    try store.switchTasks(
                        tasks: group,
                        targetProvider: target,
                        allowRisk: allowRisk,
                        allowOpaqueHistory: allowOpaqueHistory
                    )
                }
            }.value
            switch result {
            case .success(let value):
                await reloadAfterSwitch(selecting: task.id)
                let providerSummary = changesProvider
                    ? "已切换到 \(ProviderOption.displayName(for: target))。"
                    : "任务仍使用 \(ProviderOption.displayName(for: target))。"
                let compatibilitySummary = value.compatibilityFixes > 0
                    ? "\n已修复 \(value.compatibilityFixes) 条历史兼容记录。"
                    : ""
                let opaqueHistorySummary = allowOpaqueHistory
                    ? "\n已按确认从当前副本移除无法解密的历史块；完整原件保留在备份中。"
                    : ""
                statusMessage = "\(providerSummary)已创建备份，正在自动重启 Codex…"
                do {
                    try await CodexApplicationReloader.restartAndOpen(threadID: task.id) { [weak self] message in
                        self?.statusMessage = message
                    }
                    statusMessage = "切换完成，Codex 已重新打开目标会话\(compatibilitySummary)\(opaqueHistorySummary)"
                } catch {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    resultAlertTitle = "切换已保存，但重启未完成"
                    resultAlertMessage = """
                    \(providerSummary)
                    已处理 \(value.changedTasks) 个线程，修改 \(value.changedRecords) 条记录，并已创建完整备份。\(compatibilitySummary)\(opaqueHistorySummary)

                    \(error.localizedDescription)
                    """
                    statusMessage = "切换已保存，但 Codex 重新加载未完成"
                    showResultAlert = true
                }
            case .failure(let error):
                presentError(error)
                statusMessage = "切换失败，原数据已保留"
            }
            isBusy = false
        }
    }

    private func performForkAndSwitch(allowRisk: Bool) {
        guard let sourceTask = selectedTask else { return }
        let target = targetProviderID
        let store = self.store
        let forkClient = self.forkClient
        isBusy = true
        statusMessage = "正在通过 Codex 创建分支…"

        Task {
            let result = await Task.detached {
                Result<ForkSwitchResult, Error> {
                    let check = try store.preflight(
                        task: sourceTask,
                        targetProvider: target
                    )
                    if check.level == .blockedIncompatible {
                        throw SwitcherError.unsafe(check.message)
                    }
                    if !allowRisk && (check.level == .blockedRisk || check.level == .blockedUnknown) {
                        throw SwitcherError.unsafe(check.message)
                    }

                    let forkedID = try forkClient.forkThread(
                        threadID: sourceTask.id,
                        modelProvider: target
                    )
                    do {
                        var forkedTask = try store.waitForTask(id: forkedID)
                        var fallbackResult: SwitchResult?
                        let forkCheck = try store.preflight(
                            task: forkedTask,
                            targetProvider: target
                        )
                        if forkedTask.provider != target || forkCheck.compatibilityFixes > 0 {
                            fallbackResult = try store.switchTask(
                                task: forkedTask,
                                targetProvider: target,
                                allowRisk: allowRisk
                            )
                            forkedTask = try store.waitForTask(id: forkedID)
                        }
                        guard forkedTask.provider == target else {
                            throw SwitcherError.invalidData(
                                "提供商未切换成 \(ProviderOption.displayName(for: target))"
                            )
                        }
                        return ForkSwitchResult(
                            sourceThreadID: sourceTask.id,
                            forkedThreadID: forkedID,
                            targetProvider: target,
                            usedMigrationFallback: fallbackResult != nil,
                            fallbackSwitchResult: fallbackResult
                        )
                    } catch {
                        throw SwitcherError.invalidData(
                            "新分支 \(forkedID) 已创建并保留，但提供商切换未完成：\(error.localizedDescription)"
                        )
                    }
                }
            }.value

            switch result {
            case .success(let value):
                await reloadAfterSwitch(selecting: value.forkedThreadID)
                let fallbackNote = value.usedMigrationFallback
                    ? "\n当前 Codex 版本未直接保存目标提供商，App 已仅对新分支执行备份后的安全迁移。"
                    : ""
                statusMessage = "分支已创建，正在自动重启 Codex…"
                do {
                    try await CodexApplicationReloader.restartAndOpen(threadID: value.forkedThreadID) { [weak self] message in
                        self?.statusMessage = message
                    }
                    statusMessage = "分支已创建并重新打开：\(value.forkedThreadID)\(fallbackNote)"
                } catch {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    resultAlertTitle = "分支已创建，但重启未完成"
                    resultAlertMessage = """
                    原任务保持不变。
                    新分支已切换到 \(ProviderOption.displayName(for: value.targetProvider))。

                    新分支 ID：\(value.forkedThreadID)\(fallbackNote)

                    \(error.localizedDescription)
                    """
                    statusMessage = "分支已创建，但 Codex 重新加载未完成"
                    showResultAlert = true
                }
            case .failure(let error):
                presentError(error)
                statusMessage = "分支操作未完成，原任务未修改"
            }
            isBusy = false
        }
    }

    private func reloadAfterSwitch(selecting taskID: String) async {
        let store = self.store
        do {
            let updatedTasks = try await Task.detached { try store.loadTasks() }.value
            tasks = updatedTasks
            selectedTaskID = taskID
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        resultAlertTitle = "操作未完成"
        resultAlertMessage = error.localizedDescription
        showResultAlert = true
    }
}
