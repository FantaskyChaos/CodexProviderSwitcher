import Foundation

struct CodexTask: Identifiable, Hashable, Sendable {
    static let approvalReviewTitlePrefix =
        "The following is the Codex agent history whose request action you are assessing"

    let id: String
    let title: String
    let preview: String
    let indexedTitle: String?
    let provider: String
    let model: String?
    let rolloutPath: String
    let workspacePath: String
    let updatedAt: Date
    let archived: Bool
    let threadSource: String?
    let parentThreadID: String?

    var displayTitle: String {
        let indexedTitleTrimmed = indexedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !indexedTitleTrimmed.isEmpty {
            return indexedTitleTrimmed
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let previewTrimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return previewTrimmed.isEmpty ? id : previewTrimmed
    }

    var isInternalApprovalReview: Bool {
        if model == "codex-auto-review" {
            return true
        }
        return title.hasPrefix(Self.approvalReviewTitlePrefix)
            || preview.hasPrefix(Self.approvalReviewTitlePrefix)
            || (indexedTitle?.hasPrefix(Self.approvalReviewTitlePrefix) ?? false)
    }
}

enum TaskImportance {
    static let defaultsKey = "importantTaskIDs"

    static func load(from preferences: UserDefaults) -> Set<String> {
        Set(preferences.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ taskIDs: Set<String>, to preferences: UserDefaults) {
        preferences.set(taskIDs.sorted(), forKey: defaultsKey)
    }

    static func topLevelTasks(
        from tasks: [CodexTask],
        importantTaskIDs: Set<String>
    ) -> [CodexTask] {
        let knownIDs = Set(tasks.map(\.id))
        return tasks
            .filter { !$0.isInternalApprovalReview }
            .filter { task in
                guard let parentID = task.parentThreadID else { return true }
                return !knownIDs.contains(parentID)
            }
            .sorted { lhs, rhs in
                let lhsImportant = importantTaskIDs.contains(lhs.id)
                let rhsImportant = importantTaskIDs.contains(rhs.id)
                if lhsImportant != rhsImportant {
                    return lhsImportant
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id > rhs.id
            }
    }
}

enum TaskProgress {
    static let defaultsKey = "inProgressTaskIDs"

    static func load(from preferences: UserDefaults) -> Set<String> {
        Set(preferences.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ taskIDs: Set<String>, to preferences: UserDefaults) {
        preferences.set(taskIDs.sorted(), forKey: defaultsKey)
    }
}

enum TaskRelationships {
    static let defaultsKey = "conversationParentByTaskID"

    static func load(from preferences: UserDefaults) -> [String: String] {
        preferences.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func save(_ parentByTaskID: [String: String], to preferences: UserDefaults) {
        preferences.set(parentByTaskID, forKey: defaultsKey)
    }

    static func assigning(
        childID: String,
        to parentID: String,
        in parentByTaskID: [String: String]
    ) -> [String: String]? {
        guard childID != parentID else { return nil }

        var cursor: String? = parentID
        var visited: Set<String> = []
        while let current = cursor, visited.insert(current).inserted {
            guard current != childID else { return nil }
            cursor = parentByTaskID[current]
        }

        var updated = parentByTaskID
        updated[childID] = parentID
        return updated
    }

    static func pruned(
        _ parentByTaskID: [String: String],
        validTaskIDs: Set<String>
    ) -> [String: String] {
        parentByTaskID.filter { childID, parentID in
            validTaskIDs.contains(childID)
                && validTaskIDs.contains(parentID)
                && childID != parentID
        }
    }
}

enum WorkspaceScope {
    static let all = "__all_conversations__"
    static let unassigned = "__unassigned_conversations__"
}

struct ConversationWorkspace: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var parentID: String?
    var sourcePath: String?

    var isSessionWorkspace: Bool { sourcePath != nil }

    static func sessionID(for path: String) -> String {
        "cwd:\(path)"
    }
}

enum ConversationTreeLayoutPreset: String, Codable, CaseIterable, Identifiable {
    case freeform
    case vertical
    case horizontal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .freeform: return "自由布局"
        case .vertical: return "纵向树"
        case .horizontal: return "横向树"
        }
    }

    var systemImage: String {
        switch self {
        case .freeform: return "hand.draw"
        case .vertical: return "arrow.down"
        case .horizontal: return "arrow.right"
        }
    }
}

enum ConversationBoardSource: String, Codable {
    case manual
    case automatic
}

enum ConversationRelationshipCandidateStatus: String, Codable {
    case pending
    case accepted
    case rejected
}

struct ConversationRelationshipCandidate: Identifiable, Codable, Hashable {
    let id: String
    let parentID: String
    let childID: String
    var score: Int
    var reasons: [String]
    var status: ConversationRelationshipCandidateStatus = .pending

    init(
        parentID: String,
        childID: String,
        score: Int,
        reasons: [String],
        status: ConversationRelationshipCandidateStatus = .pending
    ) {
        self.id = "candidate:\(parentID):\(childID)"
        self.parentID = parentID
        self.childID = childID
        self.score = score
        self.reasons = reasons
        self.status = status
    }
}

struct ConversationTreeNode: Codable, Hashable {
    var x: Double
    var y: Double
}

struct ConversationEdgeMetadata: Codable, Hashable {
    var title: String = ""
    var note: String = ""
    var labelOffset: Double = 0
}

struct ConversationTreeRootMetadata: Codable, Hashable {
    var name: String
    var note: String = ""
    var isCollapsed: Bool = false
    var layoutPreset: ConversationTreeLayoutPreset = .horizontal
}

enum BoardAnnotationKind: String, Codable, CaseIterable {
    case text
    case group
}

enum BoardCanvasTool: String, CaseIterable, Identifiable {
    case select
    case hand
    case connect
    case text
    case group

    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "选择"
        case .hand: return "抓手"
        case .connect: return "连线"
        case .text: return "文本"
        case .group: return "说明框"
        }
    }
    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.draw"
        case .connect: return "point.3.connected.trianglepath.dotted"
        case .text: return "textformat"
        case .group: return "rectangle.dashed"
        }
    }
}

enum BoardSelection: Hashable {
    case node(String)
    case edge(String)
    case annotation(String)
    case tree(String)
}

enum BoardAlignment {
    case left, center, right, top, middle, bottom
    case distributeHorizontal, distributeVertical
}

struct BoardAnnotation: Identifiable, Codable, Hashable {
    let id: String
    var kind: BoardAnnotationKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var title: String
    var body: String
}

struct ConversationBoardViewport: Codable, Hashable {
    var offsetX: Double = 80
    var offsetY: Double = 80
    var zoom: Double = 1
}

struct ConversationBoard: Identifiable, Codable, Hashable {
    let id: String
    var workspaceID: String
    var name: String
    var layoutPreset: ConversationTreeLayoutPreset
    var nodes: [String: ConversationTreeNode]
    var parentByTaskID: [String: String]
    var roots: [String: ConversationTreeRootMetadata]
    var edges: [String: ConversationEdgeMetadata]
    var annotations: [String: BoardAnnotation]
    var viewport: ConversationBoardViewport
    var gridEnabled: Bool
    var gridSpacingX: Double
    var gridSpacingY: Double
    var source: ConversationBoardSource
    var relationshipCandidates: [ConversationRelationshipCandidate]

    init(
        id: String,
        workspaceID: String,
        name: String,
        layoutPreset: ConversationTreeLayoutPreset,
        nodes: [String: ConversationTreeNode],
        parentByTaskID: [String: String],
        roots: [String: ConversationTreeRootMetadata] = [:],
        edges: [String: ConversationEdgeMetadata] = [:],
        annotations: [String: BoardAnnotation] = [:],
        viewport: ConversationBoardViewport = ConversationBoardViewport(),
        gridEnabled: Bool = false,
        gridSpacingX: Double = 240,
        gridSpacingY: Double = 112,
        source: ConversationBoardSource = .manual,
        relationshipCandidates: [ConversationRelationshipCandidate] = []
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.layoutPreset = layoutPreset
        self.nodes = nodes
        self.parentByTaskID = parentByTaskID
        self.roots = roots
        self.edges = edges
        self.annotations = annotations
        self.viewport = viewport
        self.gridEnabled = gridEnabled
        self.gridSpacingX = gridSpacingX
        self.gridSpacingY = gridSpacingY
        self.source = source
        self.relationshipCandidates = relationshipCandidates
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, name, layoutPreset, nodes, parentByTaskID
        case roots, edges, annotations, viewport
        case gridEnabled, gridSpacingX, gridSpacingY, source, relationshipCandidates
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        name = try values.decode(String.self, forKey: .name)
        layoutPreset = try values.decodeIfPresent(ConversationTreeLayoutPreset.self, forKey: .layoutPreset) ?? .freeform
        nodes = try values.decodeIfPresent([String: ConversationTreeNode].self, forKey: .nodes) ?? [:]
        parentByTaskID = try values.decodeIfPresent([String: String].self, forKey: .parentByTaskID) ?? [:]
        roots = try values.decodeIfPresent([String: ConversationTreeRootMetadata].self, forKey: .roots) ?? [:]
        edges = try values.decodeIfPresent([String: ConversationEdgeMetadata].self, forKey: .edges) ?? [:]
        annotations = try values.decodeIfPresent([String: BoardAnnotation].self, forKey: .annotations) ?? [:]
        viewport = try values.decodeIfPresent(ConversationBoardViewport.self, forKey: .viewport) ?? ConversationBoardViewport()
        gridEnabled = try values.decodeIfPresent(Bool.self, forKey: .gridEnabled) ?? false
        gridSpacingX = max(40, try values.decodeIfPresent(Double.self, forKey: .gridSpacingX) ?? 240)
        gridSpacingY = max(40, try values.decodeIfPresent(Double.self, forKey: .gridSpacingY) ?? 112)
        source = try values.decodeIfPresent(ConversationBoardSource.self, forKey: .source) ?? .manual
        relationshipCandidates = try values.decodeIfPresent([ConversationRelationshipCandidate].self, forKey: .relationshipCandidates) ?? []
    }
}

typealias ConversationTree = ConversationBoard

struct ConversationOrganization: Codable, Hashable {
    static let defaultWorkspaceID = "workspace-default"
    static let defaultTreeID = "tree-default"

    var workspaces: [ConversationWorkspace]
    var boards: [ConversationBoard]

    var trees: [ConversationBoard] {
        get { boards }
        set { boards = newValue }
    }

    static let empty = ConversationOrganization(
        workspaces: [
            ConversationWorkspace(
                id: defaultWorkspaceID,
                name: "我的工作区",
                parentID: nil,
                sourcePath: nil
            )
        ],
        boards: [
            ConversationBoard(
                id: defaultTreeID,
                workspaceID: defaultWorkspaceID,
                name: "主画板",
                layoutPreset: .freeform,
                nodes: [:],
                parentByTaskID: [:]
            )
        ]
    )
}

enum ConversationOrganizationStore {
    static let defaultsKey = "conversationOrganizationV3"
    static let legacyDefaultsKey = "conversationOrganizationV2"

    static func load(
        from preferences: UserDefaults,
        legacyParentByTaskID: [String: String] = [:]
    ) -> ConversationOrganization {
        if let data = preferences.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(ConversationOrganization.self, from: data),
           !decoded.workspaces.isEmpty {
            return decoded
        }

        if let data = preferences.data(forKey: legacyDefaultsKey),
           let legacy = try? JSONDecoder().decode(LegacyConversationOrganization.self, from: data),
           !legacy.workspaces.isEmpty {
            let migrated = migrate(legacy)
            save(migrated, to: preferences)
            return migrated
        }

        var organization = ConversationOrganization.empty
        guard !legacyParentByTaskID.isEmpty else { return organization }
        let relatedIDs = Set(legacyParentByTaskID.keys).union(legacyParentByTaskID.values)
        if let index = organization.trees.firstIndex(where: { $0.id == ConversationOrganization.defaultTreeID }) {
            organization.trees[index].parentByTaskID = legacyParentByTaskID
            for (offset, taskID) in relatedIDs.sorted().enumerated() {
                organization.trees[index].nodes[taskID] = ConversationTreeNode(
                    x: Double(180 + (offset % 4) * 280),
                    y: Double(140 + (offset / 4) * 180)
                )
            }
        }
        return organization
    }

    static func save(_ organization: ConversationOrganization, to preferences: UserDefaults) {
        guard let data = try? JSONEncoder().encode(organization) else { return }
        preferences.set(data, forKey: defaultsKey)
    }

    private static func migrate(_ legacy: LegacyConversationOrganization) -> ConversationOrganization {
        ConversationOrganization(
            workspaces: legacy.workspaces,
            boards: legacy.trees.map { old in
                var board = ConversationBoard(
                    id: old.id,
                    workspaceID: old.workspaceID,
                    name: old.name,
                    layoutPreset: old.layoutPreset,
                    nodes: old.nodes,
                    parentByTaskID: old.parentByTaskID
                )
                for rootID in BoardGraph.roots(
                    nodeIDs: Set(old.nodes.keys),
                    parentByTaskID: old.parentByTaskID
                ) {
                    board.roots[rootID] = ConversationTreeRootMetadata(name: old.name)
                }
                return board
            }
        )
    }
}

private struct LegacyConversationOrganization: Codable {
    var workspaces: [ConversationWorkspace]
    var trees: [LegacyConversationTree]
}

private struct LegacyConversationTree: Codable {
    let id: String
    var workspaceID: String
    var name: String
    var layoutPreset: ConversationTreeLayoutPreset
    var nodes: [String: ConversationTreeNode]
    var parentByTaskID: [String: String]
}

enum BoardGraph {
    static func roots(nodeIDs: Set<String>, parentByTaskID: [String: String]) -> [String] {
        nodeIDs.filter { parentByTaskID[$0] == nil || !nodeIDs.contains(parentByTaskID[$0]!) }.sorted()
    }

    static func descendants(of rootID: String, parentByTaskID: [String: String]) -> Set<String> {
        var result: Set<String> = [rootID]
        var queue = [rootID]
        while let parent = queue.first {
            queue.removeFirst()
            for child in parentByTaskID.compactMap({ $0.value == parent ? $0.key : nil })
                where result.insert(child).inserted {
                queue.append(child)
            }
        }
        return result
    }

    static func root(of taskID: String, parentByTaskID: [String: String]) -> String {
        var cursor = taskID
        var visited: Set<String> = [taskID]
        while let parent = parentByTaskID[cursor], visited.insert(parent).inserted {
            cursor = parent
        }
        return cursor
    }

    static func normalizedMetadata(
        board: ConversationBoard,
        title: (String) -> String
    ) -> ConversationBoard {
        var updated = board
        let rootIDs = Set(roots(nodeIDs: Set(board.nodes.keys), parentByTaskID: board.parentByTaskID))
        updated.roots = board.roots.filter { rootIDs.contains($0.key) }
        for rootID in rootIDs where updated.roots[rootID] == nil {
            updated.roots[rootID] = ConversationTreeRootMetadata(name: title(rootID))
        }
        updated.edges = board.edges.filter { childID, _ in board.parentByTaskID[childID] != nil }
        return updated
    }
}

enum ConversationTreeAutoLayout {
    static func positions(
        taskIDs: [String],
        parentByTaskID: [String: String],
        preset: ConversationTreeLayoutPreset,
        spacingX: Double = 240,
        spacingY: Double = 112
    ) -> [String: CGPoint] {
        guard preset != .freeform else { return [:] }
        let validIDs = Set(taskIDs)
        let order = Dictionary(uniqueKeysWithValues: taskIDs.enumerated().map { ($0.element, $0.offset) })
        let stableSort: (String, String) -> Bool = { lhs, rhs in
            let left = order[lhs] ?? Int.max
            let right = order[rhs] ?? Int.max
            return left == right ? lhs < rhs : left < right
        }
        let parents = parentByTaskID.filter {
            validIDs.contains($0.key) && validIDs.contains($0.value)
        }

        let children = Dictionary(grouping: parents.keys, by: { parents[$0]! })
            .mapValues { $0.sorted(by: stableSort) }
        let roots = validIDs.filter { parents[$0] == nil }.sorted(by: stableSort)
        var result: [String: CGPoint] = [:]
        var nextCrossAxis: CGFloat = 0
        var visiting: Set<String> = []

        @discardableResult
        func place(_ id: String, depth: Int) -> CGFloat {
            guard visiting.insert(id).inserted else { return nextCrossAxis }
            defer { visiting.remove(id) }
            let childIDs = children[id] ?? []
            let crossAxis: CGFloat
            if childIDs.isEmpty {
                crossAxis = nextCrossAxis
                nextCrossAxis += CGFloat(preset == .horizontal ? max(40, spacingY) : max(40, spacingX))
            } else {
                let childAxes = childIDs.map { place($0, depth: depth + 1) }
                crossAxis = (childAxes.first! + childAxes.last!) / 2
            }
            switch preset {
            case .vertical:
                result[id] = CGPoint(x: crossAxis, y: CGFloat(depth) * CGFloat(max(40, spacingY)))
            case .horizontal:
                result[id] = CGPoint(x: CGFloat(depth) * CGFloat(max(40, spacingX)), y: crossAxis)
            case .freeform:
                break
            }
            return crossAxis
        }

        for root in roots {
            _ = place(root, depth: 0)
            nextCrossAxis += CGFloat(preset == .horizontal ? max(40, spacingY) : max(40, spacingX))
        }
        for id in validIDs.sorted() where result[id] == nil {
            _ = place(id, depth: 0)
        }
        return result
    }
}

enum ConversationGrid {
    static func snap(_ point: CGPoint, spacingX: Double = 240, spacingY: Double = 112) -> CGPoint {
        CGPoint(
            x: (point.x / CGFloat(max(40, spacingX))).rounded() * CGFloat(max(40, spacingX)),
            y: (point.y / CGFloat(max(40, spacingY))).rounded() * CGFloat(max(40, spacingY))
        )
    }
}

enum ConversationAutoOrganizer {
    static func candidates(
        tasks: [CodexTask],
        existing: [ConversationRelationshipCandidate] = []
    ) -> [ConversationRelationshipCandidate] {
        let valid = tasks.filter { !$0.isInternalApprovalReview }
        var result: [ConversationRelationshipCandidate] = []
        let oldStatus = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.status) })
        let grouped = Dictionary(grouping: valid, by: \.workspacePath)

        for group in grouped.values {
            let ordered = group.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id < rhs.id
            }
            for childIndex in ordered.indices {
                let child = ordered[childIndex]
                var childCandidates: [ConversationRelationshipCandidate] = []
                for parentIndex in ordered.indices where parentIndex < childIndex {
                    let parent = ordered[parentIndex]
                    var reasons: [String] = []
                    if !keywordSet(parent).isDisjoint(with: keywordSet(child)) { reasons.append("标题或摘要关键词重合") }
                    if !urlSet(parent).isDisjoint(with: urlSet(child)) { reasons.append("共享 URL 或项目标识") }
                    if child.updatedAt.timeIntervalSince(parent.updatedAt) <= 3 * 86_400 { reasons.append("时间线接近") }
                    guard reasons.count >= 2 else { continue }
                    let id = "candidate:\(parent.id):\(child.id)"
                    childCandidates.append(
                        ConversationRelationshipCandidate(
                            parentID: parent.id,
                            childID: child.id,
                            score: reasons.count,
                            reasons: reasons,
                            status: oldStatus[id] ?? .pending
                        )
                    )
                }
                result.append(contentsOf: childCandidates.sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.parentID < $1.parentID
                }.prefix(3))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func keywordSet(_ task: CodexTask) -> Set<String> {
        let source = "\(task.displayTitle) \(task.preview)".lowercased()
        let tokens = source.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        return Set(tokens)
    }

    private static func urlSet(_ task: CodexTask) -> Set<String> {
        let source = "\(task.displayTitle) \(task.preview)"
        let pattern = #"https?://[^\s)\]}>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(regex.matches(in: source, range: range).compactMap {
            guard let matchRange = Range($0.range, in: source) else { return nil }
            return String(source[matchRange]).lowercased()
        })
    }
}

enum CodexDeepLink {
    static func taskURL(threadID: String) -> URL? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(threadID)"
        return components.url
    }
}

struct ProviderOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String

    static func displayName(for id: String) -> String {
        switch id {
        case "openai":
            return "OpenAI 官方"
        case "custom":
            return "外部 API"
        default:
            return id
        }
    }
}

struct ProviderConfiguration: Sendable {
    let activeProvider: String
    let providers: [ProviderOption]
}

enum PreflightLevel: String, Sendable {
    case safe
    case alreadyTarget
    case blockedIncompatible
    case blockedOpaqueHistory
    case blockedRisk
    case blockedUnknown
}

struct ContextPreflight: Sendable {
    let level: PreflightLevel
    let latestInputTokens: Int?
    let currentContextWindow: Int?
    let targetContextWindow: Int?
    let guardrailTokens: Int?
    let headroomTokens: Int?
    let compactedEvents: Int
    let compatibilityFixes: Int
    let providerBoundItemIDs: Int
    let message: String

    init(
        level: PreflightLevel,
        latestInputTokens: Int?,
        currentContextWindow: Int?,
        targetContextWindow: Int?,
        guardrailTokens: Int?,
        headroomTokens: Int?,
        compactedEvents: Int,
        compatibilityFixes: Int = 0,
        providerBoundItemIDs: Int = 0,
        message: String
    ) {
        self.level = level
        self.latestInputTokens = latestInputTokens
        self.currentContextWindow = currentContextWindow
        self.targetContextWindow = targetContextWindow
        self.guardrailTokens = guardrailTokens
        self.headroomTokens = headroomTokens
        self.compactedEvents = compactedEvents
        self.compatibilityFixes = compatibilityFixes
        self.providerBoundItemIDs = providerBoundItemIDs
        self.message = message
    }

    static let unavailable = ContextPreflight(
        level: .blockedUnknown,
        latestInputTokens: nil,
        currentContextWindow: nil,
        targetContextWindow: nil,
        guardrailTokens: nil,
        headroomTokens: nil,
        compactedEvents: 0,
        compatibilityFixes: 0,
        providerBoundItemIDs: 0,
        message: "请选择一个任务"
    )
}

struct SwitchResult: Sendable {
    let changedTasks: Int
    let changedRecords: Int
    let rolloutBackups: [String]
    let databaseBackup: String
    let compatibilityFixes: Int
}

struct ForkSwitchResult: Sendable {
    let sourceThreadID: String
    let forkedThreadID: String
    let targetProvider: String
    let usedMigrationFallback: Bool
    let fallbackSwitchResult: SwitchResult?
}

struct RolloutContextState: Sendable {
    var latestInputTokens: Int?
    var latestContextWindow: Int?
    var compactedEvents = 0
}

enum SwitcherError: LocalizedError {
    case missingFile(String)
    case invalidData(String)
    case database(String)
    case unsafe(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let value),
             .invalidData(let value),
             .database(let value),
             .unsafe(let value):
            return value
        }
    }
}
