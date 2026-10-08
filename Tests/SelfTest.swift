import CSQLite
import Foundation

@main
struct SelfTest {
    static func main() throws {
        try testLoadsEveryTaskAndConfiguredProviders()
        try testImportantTasksPersistAndSortFirst()
        try testInternalApprovalReviewsStayOutOfMainList()
        try testInProgressTasksPersist()
        try testConversationRelationshipsPersistAndRejectCycles()
        try testWorkspaceTreesPersistAndMigrateLegacyRelationships()
        try testBoardV3MigrationAndMetadata()
        try testGridAndAutoOrganizationModels()
        try testCurrentThreadDetection()
        try testCodexTaskDeepLink()
        try testForkProtocolUsesOfficialMethodAndTargetProvider()
        try testForkResponseScannerHandlesChunkedLargeResponse()
        try testSafeSwitchUpdatesJSONLAndDatabaseWithBackups()
        try testBatchSwitchChecksIndependentRootsAndWritesOnce()
        try testSafeSwitchFromOfficialToExternal()
        try testProviderBoundItemIDsBlockEvenForcedSwitch()
        try testRepairsDatabaseWhenRolloutAlreadyUsesTargetProvider()
        try testRepairsCompatibilityWhenAlreadyOfficial()
        try testRiskGuardBlocksMutationWithoutExplicitOverride()
        try runOptionalOfficialForkSmokeTest()
        try runOptionalCompatibilityRepair()
        print("All CodexProviderSwitcher self-tests passed.")
    }

    private static func runOptionalCompatibilityRepair() throws {
        guard let threadID = ProcessInfo.processInfo.environment["CODEX_REPAIR_THREAD_ID"],
              !threadID.isEmpty else {
            return
        }
        let store = CodexStore()
        let task = try require(
            store.loadTasks().first(where: { $0.id == threadID }),
            "Compatibility repair task missing"
        )
        let before = try store.officialCompatibilityFixCount(
            task: task,
            targetProvider: "openai"
        )
        guard before > 0 else {
            print("Official compatibility repair not needed: \(threadID)")
            return
        }
        let result = try store.switchTask(task: task, targetProvider: "openai")
        let updated = try require(
            store.loadTasks().first(where: { $0.id == threadID }),
            "Repaired task missing"
        )
        let after = try store.officialCompatibilityFixCount(
            task: updated,
            targetProvider: "openai"
        )
        try expect(after == 0, "Official compatibility repair left invalid IDs")
        print(
            "Official compatibility repair passed: \(threadID), "
            + "fixed \(result.compatibilityFixes), backup \(result.rolloutBackups.joined())"
        )
    }

    private static func runOptionalOfficialForkSmokeTest() throws {
        guard let sourceID = ProcessInfo.processInfo.environment["CODEX_FORK_SMOKE_THREAD_ID"],
              !sourceID.isEmpty else {
            return
        }
        let provider = ProcessInfo.processInfo.environment["CODEX_FORK_SMOKE_PROVIDER"] ?? "openai"
        let forkedID = try CodexForkClient().forkThread(
            threadID: sourceID,
            modelProvider: provider,
            ephemeral: true
        )
        try expect(forkedID != sourceID, "Official fork returned the source thread ID")
        print("Official ephemeral fork smoke test passed: \(forkedID)")
    }

    private static func testInProgressTasksPersist() throws {
        let preferencesName = "CodexProviderSwitcherProgressSelfTest-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: preferencesName) else {
            throw NSError(domain: "Fixture", code: 6)
        }
        defer { preferences.removePersistentDomain(forName: preferencesName) }

        let taskIDs: Set<String> = [Fixture.sourceID, Fixture.targetID]
        TaskProgress.save(taskIDs, to: preferences)
        try expect(
            TaskProgress.load(from: preferences) == taskIDs,
            "In-progress task labels did not persist"
        )
    }

    private static func testConversationRelationshipsPersistAndRejectCycles() throws {
        let preferencesName = "CodexProviderSwitcherRelationshipsSelfTest-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: preferencesName) else {
            throw NSError(domain: "Fixture", code: 7)
        }
        defer { preferences.removePersistentDomain(forName: preferencesName) }

        let first = Fixture.sourceID
        let second = Fixture.targetID
        let third = Fixture.childID
        var relationships: [String: String] = [:]
        relationships = try require(
            TaskRelationships.assigning(childID: second, to: first, in: relationships),
            "Valid parent relationship was rejected"
        )
        relationships = try require(
            TaskRelationships.assigning(childID: third, to: second, in: relationships),
            "Valid nested relationship was rejected"
        )
        try expect(
            TaskRelationships.assigning(childID: first, to: third, in: relationships) == nil,
            "Cyclic parent relationship should be rejected"
        )

        TaskRelationships.save(relationships, to: preferences)
        try expect(
            TaskRelationships.load(from: preferences) == relationships,
            "Conversation relationships did not persist"
        )
    }

    private static func testWorkspaceTreesPersistAndMigrateLegacyRelationships() throws {
        let preferencesName = "CodexProviderSwitcherOrganizationSelfTest-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: preferencesName) else {
            throw NSError(domain: "Fixture", code: 8)
        }
        defer { preferences.removePersistentDomain(forName: preferencesName) }

        let legacy = [Fixture.targetID: Fixture.sourceID]
        var organization = ConversationOrganizationStore.load(
            from: preferences,
            legacyParentByTaskID: legacy
        )
        let defaultTree = try require(
            organization.trees.first(where: { $0.id == ConversationOrganization.defaultTreeID }),
            "Default conversation tree missing"
        )
        try expect(
            defaultTree.parentByTaskID == legacy
                && defaultTree.nodes[Fixture.sourceID] != nil
                && defaultTree.nodes[Fixture.targetID] != nil,
            "Legacy relationships were not migrated into the default tree"
        )

        let childWorkspace = ConversationWorkspace(
            id: "workspace-child",
            name: "Child Workspace",
            parentID: ConversationOrganization.defaultWorkspaceID,
            sourcePath: nil
        )
        organization.workspaces.append(childWorkspace)
        organization.trees.append(
            ConversationTree(
                id: "tree-child",
                workspaceID: childWorkspace.id,
                name: "Child Tree",
                layoutPreset: .vertical,
                nodes: [Fixture.childID: ConversationTreeNode(x: 200, y: 200)],
                parentByTaskID: [:]
            )
        )
        ConversationOrganizationStore.save(organization, to: preferences)
        try expect(
            ConversationOrganizationStore.load(from: preferences) == organization,
            "Nested workspaces and multiple trees did not persist"
        )

        let positions = ConversationTreeAutoLayout.positions(
            taskIDs: [Fixture.sourceID, Fixture.targetID],
            parentByTaskID: legacy,
            preset: .vertical
        )
        try expect(
            positions[Fixture.targetID]!.y > positions[Fixture.sourceID]!.y,
            "Vertical layout did not place a child below its parent"
        )
    }

    private static func testBoardV3MigrationAndMetadata() throws {
        let preferencesName = "CodexProviderSwitcherBoardV3SelfTest-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: preferencesName) else {
            throw NSError(domain: "Fixture", code: 9)
        }
        defer { preferences.removePersistentDomain(forName: preferencesName) }

        let legacyObject: [String: Any] = [
            "workspaces": [[
                "id": "workspace-v2", "name": "Legacy", "parentID": NSNull(), "sourcePath": "/fixture/workspace"
            ]],
            "trees": [[
                "id": "board-v2", "workspaceID": "workspace-v2", "name": "旧树",
                "layoutPreset": "vertical",
                "nodes": [
                    Fixture.sourceID: ["x": 180.0, "y": 130.0],
                    Fixture.targetID: ["x": 180.0, "y": 330.0],
                    Fixture.childID: ["x": 520.0, "y": 130.0]
                ],
                "parentByTaskID": [Fixture.targetID: Fixture.sourceID]
            ]]
        ]
        preferences.set(try JSONSerialization.data(withJSONObject: legacyObject),
                        forKey: ConversationOrganizationStore.legacyDefaultsKey)

        var organization = ConversationOrganizationStore.load(from: preferences)
        let board = try require(organization.boards.first, "V2 tree was not migrated into a board")
        try expect(board.nodes.count == 3 && board.parentByTaskID.count == 1,
                   "V2 nodes or edges were lost during board migration")
        try expect(Set(board.roots.keys) == Set([Fixture.sourceID, Fixture.childID]),
                   "Multiple legacy roots were not represented as named trees")
        try expect(preferences.data(forKey: ConversationOrganizationStore.defaultsKey) != nil,
                   "Migrated V3 board data was not persisted")

        organization.boards[0].roots[Fixture.sourceID]?.note = "主线说明"
        organization.boards[0].edges[Fixture.targetID] = ConversationEdgeMetadata(
            title: "继续推进", note: "完整关系备注", labelOffset: 0.15
        )
        let annotationID = "annotation-fixture"
        organization.boards[0].annotations[annotationID] = BoardAnnotation(
            id: annotationID, kind: .group, x: 400, y: 400,
            width: 360, height: 220, title: "阶段一", body: "范围说明"
        )
        ConversationOrganizationStore.save(organization, to: preferences)
        let reloaded = ConversationOrganizationStore.load(from: preferences)
        try expect(reloaded.boards[0].roots[Fixture.sourceID]?.note == "主线说明",
                   "Tree explanation did not persist")
        try expect(reloaded.boards[0].edges[Fixture.targetID]?.note == "完整关系备注",
                   "Edge explanation did not persist")
        try expect(reloaded.boards[0].annotations[annotationID]?.kind == .group,
                   "Board annotation did not persist")

        let positions = ConversationTreeAutoLayout.positions(
            taskIDs: [Fixture.sourceID, Fixture.targetID, Fixture.childID],
            parentByTaskID: [Fixture.targetID: Fixture.sourceID, Fixture.childID: Fixture.sourceID],
            preset: .vertical
        )
        let rootX = try require(positions[Fixture.sourceID]?.x, "Layout root missing")
        let childXs = [positions[Fixture.targetID]!.x, positions[Fixture.childID]!.x]
        try expect(rootX == (childXs[0] + childXs[1]) / 2,
                   "Tree-aware layout did not center the parent above its children")
    }

    private static func testGridAndAutoOrganizationModels() throws {
        let snapped = ConversationGrid.snap(CGPoint(x: 100, y: 40))
        try expect(snapped == CGPoint(x: 0, y: 0), "Grid snap did not use the configured origin")
        let later = ConversationGrid.snap(CGPoint(x: 251, y: 119))
        try expect(later == CGPoint(x: 240, y: 112), "Grid snap did not use the default spacing")

        let first = CodexTask(
            id: Fixture.sourceID, title: "Build editor", preview: "shared project https://example.com/editor",
            indexedTitle: nil, provider: "custom", model: nil, rolloutPath: "first", workspacePath: "/workspace",
            updatedAt: Date(timeIntervalSince1970: 100), archived: false, threadSource: "user", parentThreadID: nil
        )
        let second = CodexTask(
            id: Fixture.targetID, title: "Build editor tests", preview: "shared project https://example.com/editor",
            indexedTitle: nil, provider: "custom", model: nil, rolloutPath: "second", workspacePath: "/workspace",
            updatedAt: Date(timeIntervalSince1970: 200), archived: true, threadSource: "user", parentThreadID: nil
        )
        let child = CodexTask(
            id: Fixture.childID, title: "Child worker", preview: "", indexedTitle: nil, provider: "custom", model: nil,
            rolloutPath: "child", workspacePath: "/workspace", updatedAt: Date(timeIntervalSince1970: 150), archived: false,
            threadSource: "subagent", parentThreadID: Fixture.sourceID
        )
        let candidates = ConversationAutoOrganizer.candidates(tasks: [first, second, child])
        try expect(candidates.contains { $0.parentID == first.id && $0.childID == second.id },
                   "Semantic relationship candidate was not generated")
        let positions = ConversationTreeAutoLayout.positions(
            taskIDs: [first.id, child.id], parentByTaskID: [child.id: first.id], preset: .horizontal
        )
        try expect(positions[first.id]!.x < positions[child.id]!.x, "Horizontal auto-layout did not place child to the right")
        try expect(positions[first.id]!.y == positions[child.id]!.y, "Parent was not centered on its only child")

        let board = ConversationBoard(
            id: "grid-board", workspaceID: "workspace", name: "Automatic", layoutPreset: .horizontal,
            nodes: [first.id: ConversationTreeNode(x: 0, y: 0)], parentByTaskID: [:], gridEnabled: true,
            source: .automatic, relationshipCandidates: candidates
        )
        let data = try JSONEncoder().encode(board)
        let reloaded = try JSONDecoder().decode(ConversationBoard.self, from: data)
        try expect(reloaded.gridEnabled && reloaded.source == .automatic, "Grid board metadata did not persist")
        try expect(reloaded.relationshipCandidates.count == candidates.count, "Relationship candidates did not persist")
    }

    private static func testCodexTaskDeepLink() throws {
        let url = try require(
            CodexDeepLink.taskURL(threadID: Fixture.sourceID),
            "Valid task ID did not produce a Codex deep link"
        )
        try expect(
            url.absoluteString == "codex://threads/\(Fixture.sourceID)",
            "Codex deep link format is incorrect"
        )
        try expect(
            CodexDeepLink.taskURL(threadID: "not-a-thread-id") == nil,
            "Invalid task ID should not produce a deep link"
        )
    }

    private static func testCurrentThreadDetection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCurrentThreadDetector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let loadedTasks = try CodexStore(codexHome: fixture.root).loadTasks()

        let firstID = Fixture.sourceID
        let secondID = Fixture.targetID
        let log = root.appendingPathComponent("codex-desktop-session-4242-t0-i1-test-0.log")
        let contents = """
        2026-08-30T10:00:00.000Z info thread_stream_view_activity_changed active=true conversationId=\(firstID) rendererWindowAppearance=primary rendererWindowFocused=true rendererWindowVisible=true
        2026-08-30T10:01:00.000Z info thread_stream_view_activity_changed active=true conversationId=\(secondID) rendererWindowAppearance=primary rendererWindowFocused=true rendererWindowVisible=true
        2026-08-30T10:02:00.000Z info thread_stream_view_activity_changed active=true conversationId=\(firstID) rendererWindowAppearance=primary rendererWindowFocused=false rendererWindowVisible=true
        """
        try contents.write(to: log, atomically: true, encoding: .utf8)

        let detector = CodexCurrentThreadDetector(logsRoot: root)
        try expect(
            detector.detect(
                tasks: loadedTasks,
                processIdentifiers: [4242],
                currentTitleOverride: "容量参考任务",
                accessibilityTrustedOverride: true
            ) == .found(secondID),
            "Current thread detector did not resolve the live Codex title"
        )

        let duplicateTasks = loadedTasks.filter { [firstID, secondID].contains($0.id) }.map { task in
            CodexTask(
                id: task.id,
                title: task.title,
                preview: task.preview,
                indexedTitle: "重复标题",
                provider: task.provider,
                model: task.model,
                rolloutPath: task.rolloutPath,
                workspacePath: task.workspacePath,
                updatedAt: task.updatedAt,
                archived: task.archived,
                threadSource: task.threadSource,
                parentThreadID: task.parentThreadID
            )
        }
        try expect(
            detector.detect(
                tasks: duplicateTasks,
                processIdentifiers: [4242],
                currentTitleOverride: "重复标题",
                accessibilityTrustedOverride: true
            ) == .found(secondID),
            "Duplicate live titles did not use the matching focused log ID"
        )
        try expect(
            detector.detect(
                tasks: loadedTasks,
                processIdentifiers: [4242],
                currentTitleOverride: "尚未保存的新会话",
                accessibilityTrustedOverride: true
            ) == .unavailableTitle("尚未保存的新会话"),
            "Unknown live title should not fall back to an older task"
        )
        try expect(
            detector.detect(
                tasks: loadedTasks,
                processIdentifiers: [4242],
                accessibilityTrustedOverride: false
            ) == .found(secondID),
            "Latest Codex activity should remain usable without accessibility permission"
        )
    }

    private static func testForkProtocolUsesOfficialMethodAndTargetProvider() throws {
        let payload = try CodexForkProtocol.requestPayload(
            threadID: Fixture.sourceID,
            modelProvider: "custom",
            lastTurnID: nil,
            ephemeral: false
        )
        let lines = payload.split(separator: 0x0A)
        try expect(lines.count == 3, "Fork protocol should send the handshake and one request")

        let forkObject = try require(
            JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any],
            "Fork request was not valid JSON"
        )
        try expect(forkObject["method"] as? String == "thread/fork", "Wrong fork method")
        let parameters = try require(
            forkObject["params"] as? [String: Any],
            "Fork request parameters missing"
        )
        try expect(parameters["threadId"] as? String == Fixture.sourceID, "Source ID missing")
        try expect(parameters["modelProvider"] as? String == "custom", "Target provider missing")
        try expect(parameters["ephemeral"] as? Bool == false, "Persistent fork was not requested")
        try expect(parameters["lastTurnId"] == nil, "Latest completed history should be the default")
    }

    private static func testForkResponseScannerHandlesChunkedLargeResponse() throws {
        let forkedID = "44444444-4444-7444-8444-444444444444"
        let prefix = "{\"id\":2,\"result\":{\"thread\":{\"id\":\"\(forkedID)\",\"turns\":["
        var scanner = CodexForkResponseScanner()
        scanner.consume(Data(prefix.prefix(25).utf8))
        try expect(scanner.threadID == nil, "Scanner should wait for a complete thread ID")
        scanner.consume(Data(prefix.dropFirst(25).utf8))
        scanner.consume(Data(repeating: 0x78, count: 1_000_000))
        try expect(scanner.threadID == forkedID, "Scanner did not extract the forked thread ID")
    }

    private static func testImportantTasksPersistAndSortFirst() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let preferencesName = "CodexProviderSwitcherSelfTest-\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: preferencesName) else {
            throw NSError(domain: "Fixture", code: 5)
        }
        defer { preferences.removePersistentDomain(forName: preferencesName) }

        let importantIDs: Set<String> = [Fixture.targetID]
        TaskImportance.save(importantIDs, to: preferences)
        try expect(
            TaskImportance.load(from: preferences) == importantIDs,
            "Important task IDs did not persist"
        )

        let tasks = try CodexStore(codexHome: fixture.root).loadTasks()
        let ordered = TaskImportance.topLevelTasks(
            from: tasks,
            importantTaskIDs: importantIDs
        )
        try expect(
            ordered.map(\.id) == [Fixture.targetID, Fixture.sourceID],
            "Important task was not pinned ahead of a more recently updated task"
        )
        try expect(
            !ordered.contains(where: { $0.id == Fixture.childID }),
            "Linked subagent should remain folded into its main task"
        )
    }

    private static func testInternalApprovalReviewsStayOutOfMainList() throws {
        let fixture = try Fixture(includeInternalReview: true)
        defer { fixture.cleanup() }

        let tasks = try CodexStore(codexHome: fixture.root).loadTasks()
        let review = try require(
            tasks.first(where: { $0.id == Fixture.internalReviewID }),
            "Internal approval review fixture missing"
        )
        try expect(review.isInternalApprovalReview, "Internal approval review was not detected")

        let ordered = TaskImportance.topLevelTasks(
            from: tasks,
            importantTaskIDs: [Fixture.internalReviewID]
        )
        try expect(
            !ordered.contains(where: { $0.id == Fixture.internalReviewID }),
            "Internal approval review should not appear in the main task list"
        )
    }

    private static func testLoadsEveryTaskAndConfiguredProviders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let tasks = try store.loadTasks()
        let configuration = try store.loadProviderConfiguration()

        try expect(tasks.count == 3, "Expected all threads to load")
        try expect(tasks.contains(where: { $0.archived }), "Expected archived tasks to load")
        let source = try require(
            tasks.first(where: { $0.id == Fixture.sourceID }),
            "Source task missing"
        )
        try expect(
            source.displayTitle == "Codex 当前任务名称",
            "Expected latest session index title to match Codex"
        )
        try expect(
            source.workspacePath == "/fixture/workspace",
            "Expected Codex cwd to load as the session workspace"
        )
        let child = try require(
            tasks.first(where: { $0.id == Fixture.childID }),
            "Subagent task missing"
        )
        try expect(child.parentThreadID == Fixture.sourceID, "Subagent parent was not parsed")
        try expect(configuration.activeProvider == "custom", "Expected custom active provider")
        try expect(
            Set(configuration.providers.map(\.id)) == Set(["openai", "custom"]),
            "Expected configured provider list"
        )
    }

    private static func testSafeSwitchUpdatesJSONLAndDatabaseWithBackups() throws {
        let fixture = try Fixture(inputTokens: 1_000)
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let tasks = try store.loadTasks()
        let task = try require(
            tasks.first(where: { $0.id == Fixture.sourceID }),
            "Source task missing"
        )
        let child = try require(
            tasks.first(where: { $0.id == Fixture.childID }),
            "Child task missing"
        )
        let group = [task, child]
        let preflight = try store.preflight(tasks: group, targetProvider: "openai")
        try expect(preflight.level == .safe, "Expected safe preflight")
        try expect(preflight.targetContextWindow == 20_000, "Expected observed target window")

        let result = try store.switchTasks(tasks: group, targetProvider: "openai")
        try expect(result.changedTasks == 2, "Expected parent and child to switch together")
        try expect(result.changedRecords > 0, "Expected session metadata changes")
        try expect(result.compatibilityFixes == 1, "Expected one tool-search ID repair")
        try expect(result.rolloutBackups.count == 2, "Expected one backup per rollout")
        for backup in result.rolloutBackups {
            try expect(FileManager.default.fileExists(atPath: backup), "Rollout backup missing")
        }
        try expect(
            FileManager.default.fileExists(atPath: result.databaseBackup),
            "Database backup missing"
        )

        let updated = try require(
            store.loadTasks().first(where: { $0.id == Fixture.sourceID }),
            "Updated task missing"
        )
        try expect(updated.provider == "openai", "Database provider was not updated")
        let updatedChild = try require(
            store.loadTasks().first(where: { $0.id == Fixture.childID }),
            "Updated child missing"
        )
        try expect(updatedChild.provider == "openai", "Child provider was not updated")
        let rollout = try String(contentsOfFile: updated.rolloutPath, encoding: .utf8)
        try expect(rollout.contains(#""model_provider":"openai""#), "JSONL was not updated")
        try expect(!rollout.contains(#""model_provider":"custom""#), "Old provider remains in JSONL")
        try expect(
            rollout.contains(#""id":"tsc_fixture_0""#)
                && !rollout.contains(#""id":"ts_fixture_0""#),
            "Official tool-search ID was not repaired"
        )
    }

    private static func testRepairsCompatibilityWhenAlreadyOfficial() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let task = try require(
            store.loadTasks().first(where: { $0.id == Fixture.targetID }),
            "Official repair task missing"
        )
        let preflight = try store.preflight(task: task, targetProvider: "openai")
        try expect(preflight.level == .safe, "Compatibility repair should be actionable")
        try expect(preflight.compatibilityFixes == 1, "Compatibility issue was not detected")

        let result = try store.switchTask(task: task, targetProvider: "openai")
        try expect(result.compatibilityFixes == 1, "Same-provider repair was not reported")
        let rollout = try String(contentsOfFile: task.rolloutPath, encoding: .utf8)
        try expect(
            rollout.contains(#""id":"tsc_official_fixture_0""#)
                && !rollout.contains(#""id":"ts_official_fixture_0""#),
            "Same-provider official repair did not rewrite the tool-search ID"
        )
    }

    private static func testBatchSwitchChecksIndependentRootsAndWritesOnce() throws {
        let fixture = try Fixture(
            inputTokens: 1_000,
            includeInternalReview: true,
            targetProvider: "custom",
            internalReviewProvider: "openai"
        )
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let tasks = try store.loadTasks()
        let source = try require(
            tasks.first(where: { $0.id == Fixture.sourceID }),
            "Batch source task missing"
        )
        let target = try require(
            tasks.first(where: { $0.id == Fixture.targetID }),
            "Batch second root missing"
        )
        let child = try require(
            tasks.first(where: { $0.id == Fixture.childID }),
            "Batch child missing"
        )
        let group = [source, target, child]
        let preflight = try store.preflight(tasks: group, targetProvider: "openai")
        try expect(preflight.level == .safe, "Batch roots should pass preflight")
        try expect(
            preflight.message.contains("批量检查 2 个主任务"),
            "Batch preflight did not identify both independent roots"
        )

        let result = try store.switchTasks(tasks: group, targetProvider: "openai")
        try expect(result.changedTasks == 3, "Batch switch did not update every related thread")
        try expect(result.rolloutBackups.count == 3, "Batch switch did not back up every rollout")
        let updated = try store.loadTasks()
        try expect(
            group.allSatisfy { original in
                updated.first(where: { $0.id == original.id })?.provider == "openai"
            },
            "Batch switch left a thread on the old provider"
        )
    }

    private static func testRiskGuardBlocksMutationWithoutExplicitOverride() throws {
        let fixture = try Fixture(inputTokens: 17_000)
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let task = try require(
            store.loadTasks().first(where: { $0.id == Fixture.sourceID }),
            "Source task missing"
        )
        let preflight = try store.preflight(task: task, targetProvider: "openai")
        try expect(preflight.level == .blockedRisk, "Expected blocked risk preflight")

        var wasBlocked = false
        do {
            _ = try store.switchTask(task: task, targetProvider: "openai")
        } catch {
            wasBlocked = true
        }
        try expect(wasBlocked, "Risk guard did not block the write")

        let unchanged = try require(
            store.loadTasks().first(where: { $0.id == Fixture.sourceID }),
            "Unchanged task missing"
        )
        try expect(unchanged.provider == "custom", "Blocked database was modified")
        let rollout = try String(contentsOfFile: unchanged.rolloutPath, encoding: .utf8)
        try expect(rollout.contains(#""model_provider":"custom""#), "Blocked JSONL was modified")
    }

    private static func testSafeSwitchFromOfficialToExternal() throws {
        let fixture = try Fixture(inputTokens: 1_000)
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let task = try require(
            store.loadTasks().first(where: { $0.id == Fixture.targetID }),
            "Official task missing"
        )
        let preflight = try store.preflight(task: task, targetProvider: "custom")
        try expect(preflight.level == .safe, "Expected safe external preflight")

        _ = try store.switchTask(task: task, targetProvider: "custom")
        let updated = try require(
            store.loadTasks().first(where: { $0.id == Fixture.targetID }),
            "External task missing after switch"
        )
        try expect(updated.provider == "custom", "Official task did not switch to external")
        let rollout = try String(contentsOfFile: updated.rolloutPath, encoding: .utf8)
        try expect(rollout.contains(#""model_provider":"custom""#), "External JSONL was not updated")
    }

    private static func testProviderBoundItemIDsBlockEvenForcedSwitch() throws {
        let fixture = try Fixture(inputTokens: 1_000, includeProviderBoundItem: true)
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let task = try require(
            store.loadTasks().first(where: { $0.id == Fixture.sourceID }),
            "Provider-bound task missing"
        )
        let preflight = try store.preflight(task: task, targetProvider: "openai")
        try expect(
            preflight.level == .blockedIncompatible,
            "Provider-bound item IDs should block a cross-provider switch"
        )
        try expect(preflight.providerBoundItemIDs == 1, "Provider-bound item count was wrong")

        var wasBlocked = false
        do {
            _ = try store.switchTask(
                task: task,
                targetProvider: "openai",
                allowRisk: true
            )
        } catch {
            wasBlocked = true
        }
        try expect(wasBlocked, "Forced switch bypassed provider-bound item protection")

        let unchanged = try require(
            store.loadTasks().first(where: { $0.id == Fixture.sourceID }),
            "Blocked task missing after preflight"
        )
        try expect(unchanged.provider == "custom", "Blocked database was modified")
        let rollout = try String(contentsOfFile: unchanged.rolloutPath, encoding: .utf8)
        try expect(rollout.contains(#""model_provider":"custom""#), "Blocked rollout was modified")
    }

    private static func testRepairsDatabaseWhenRolloutAlreadyUsesTargetProvider() throws {
        let fixture = try Fixture(inputTokens: 1_000)
        defer { fixture.cleanup() }

        let store = CodexStore(codexHome: fixture.root)
        let task = try require(
            store.loadTasks().first(where: { $0.id == Fixture.targetID }),
            "Inconsistent task missing"
        )
        let rolloutURL = URL(fileURLWithPath: task.rolloutPath)
        let rollout = try String(contentsOf: rolloutURL, encoding: .utf8)
            .replacingOccurrences(
                of: #""model_provider":"openai""#,
                with: #""model_provider":"custom""#
            )
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let result = try store.switchTask(task: task, targetProvider: "custom")
        try expect(result.changedRecords == 0, "Already-target rollout should not be rewritten")
        let updated = try require(
            store.loadTasks().first(where: { $0.id == Fixture.targetID }),
            "Reconciled task missing"
        )
        try expect(updated.provider == "custom", "Database provider was not reconciled")
        let reconciledRollout = try String(contentsOf: rolloutURL, encoding: .utf8)
        try expect(
            reconciledRollout.contains(#""model_provider":"custom""#),
            "Target provider was lost from rollout"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw NSError(
                domain: "CodexProviderSwitcherSelfTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(
                domain: "CodexProviderSwitcherSelfTest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return value
    }
}

private final class Fixture {
    static let sourceID = "11111111-1111-7111-8111-111111111111"
    static let targetID = "22222222-2222-7222-8222-222222222222"
    static let childID = "33333333-3333-7333-8333-333333333333"
    static let internalReviewID = "44444444-4444-7444-8444-444444444444"

    let root: URL
    private let sessions: URL

    init(
        inputTokens: Int = 1_000,
        includeInternalReview: Bool = false,
        includeProviderBoundItem: Bool = false,
        targetProvider: String = "openai",
        internalReviewProvider: String = "custom"
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProviderSwitcherTests-\(UUID().uuidString)", isDirectory: true)
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let config = """
        model = "test-model"
        model_provider = "custom"

        [model_providers.custom]
        name = "External"
        """
        try config.write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let sessionIndex = """
        {"id":"\(Self.sourceID)","thread_name":"旧任务名称","updated_at":"2026-01-01T00:00:00Z"}
        {"id":"\(Self.sourceID)","thread_name":"Codex 当前任务名称","updated_at":"2026-01-02T00:00:00Z"}
        """
        try sessionIndex.write(
            to: root.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sourceRollout = sessions.appendingPathComponent("rollout-\(Self.sourceID).jsonl")
        let targetRollout = sessions.appendingPathComponent("rollout-\(Self.targetID).jsonl")
        let childRollout = sessions.appendingPathComponent("rollout-\(Self.childID).jsonl")
        let internalReviewRollout = sessions.appendingPathComponent("rollout-\(Self.internalReviewID).jsonl")
        try makeRollout(
            at: sourceRollout,
            id: Self.sourceID,
            provider: "custom",
            inputTokens: inputTokens,
            contextWindow: 20_000,
            legacyToolSearchID: "ts_fixture_0",
            includeProviderBoundItem: includeProviderBoundItem
        )
        try makeRollout(
            at: targetRollout,
            id: Self.targetID,
            provider: targetProvider,
            inputTokens: 2_000,
            contextWindow: 20_000,
            legacyToolSearchID: "ts_official_fixture_0"
        )
        try makeRollout(
            at: childRollout,
            id: Self.childID,
            provider: "custom",
            inputTokens: 1_500,
            contextWindow: 20_000
        )
        if includeInternalReview {
            try makeRollout(
                at: internalReviewRollout,
                id: Self.internalReviewID,
                provider: internalReviewProvider,
                inputTokens: 1_500,
                contextWindow: 20_000
            )
        }
        try createDatabase(
            sourceRollout: sourceRollout,
            targetRollout: targetRollout,
            childRollout: childRollout,
            internalReviewRollout: includeInternalReview ? internalReviewRollout : nil,
            targetProvider: targetProvider,
            internalReviewProvider: internalReviewProvider
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRollout(
        at url: URL,
        id: String,
        provider: String,
        inputTokens: Int,
        contextWindow: Int,
        legacyToolSearchID: String? = nil,
        includeProviderBoundItem: Bool = false
    ) throws {
        var lines = [
            #"{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","model_provider":"\#(provider)"}}"#,
            #"{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"task_started","model_context_window":\#(contextWindow)}}"#,
            #"{"timestamp":"2026-01-01T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(inputTokens)},"model_context_window":\#(contextWindow)}}}"#
        ]
        if let legacyToolSearchID {
            lines.insert(
                #"{"timestamp":"2026-01-01T00:00:01Z","type":"response_item","payload":{"type":"tool_search_call","id":"\#(legacyToolSearchID)","call_id":"sg_call_fixture_0","status":"completed"}}"#,
                at: 1
            )
        }
        if includeProviderBoundItem {
            lines.append(
                #"{"timestamp":"2026-01-01T00:00:03Z","type":"response_item","payload":{"type":"message","id":"msg_provider_fixture_0","role":"assistant","content":[]},"metadata":{"retained_source":{"id":{"message_id":"msg_provider_fixture_0","role":"assistant"},"revision":"retained_fixture","complete":true}}}"#
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func createDatabase(
        sourceRollout: URL,
        targetRollout: URL,
        childRollout: URL,
        internalReviewRollout: URL?,
        targetProvider: String,
        internalReviewProvider: String
    ) throws {
        var database: OpaquePointer?
        let path = root.appendingPathComponent("state_5.sqlite").path
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "Fixture", code: 1)
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            preview TEXT NOT NULL,
            model_provider TEXT NOT NULL,
            model TEXT,
            rollout_path TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL,
            thread_source TEXT,
            cwd TEXT NOT NULL
        );
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Fixture", code: 2)
        }

        try insert(
            database: database,
            id: Self.sourceID,
            title: "需要切换的任务",
            provider: "custom",
            rolloutPath: sourceRollout.path,
            updatedAt: 200,
            archived: 0,
            source: "app",
            threadSource: "user"
        )
        try insert(
            database: database,
            id: Self.targetID,
            title: "容量参考任务",
            provider: targetProvider,
            rolloutPath: targetRollout.path,
            updatedAt: 100,
            archived: 1,
            source: "app",
            threadSource: "user"
        )
        try insert(
            database: database,
            id: Self.childID,
            title: "子代理审查",
            provider: "custom",
            rolloutPath: childRollout.path,
            updatedAt: 150,
            archived: 0,
            source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(Self.sourceID)"}}}"#,
            threadSource: "subagent"
        )
        if let internalReviewRollout {
            try insert(
                database: database,
                id: Self.internalReviewID,
                title: CodexTask.approvalReviewTitlePrefix + ":",
                provider: internalReviewProvider,
                rolloutPath: internalReviewRollout.path,
                updatedAt: 300,
                archived: 0,
                source: "app",
                threadSource: "user",
                model: internalReviewProvider == "openai" ? "test-model" : "gpt-5.6-luna"
            )
        }
    }

    private func insert(
        database: OpaquePointer,
        id: String,
        title: String,
        provider: String,
        rolloutPath: String,
        updatedAt: Int,
        archived: Int,
        source: String,
        threadSource: String,
        model: String = "test-model"
    ) throws {
        let sql = """
        INSERT INTO threads
        (id, title, preview, model_provider, model, rollout_path, updated_at, archived, source, thread_source, cwd)
        VALUES (?, ?, '', ?, ?, ?, ?, ?, ?, ?, '/fixture/workspace')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Fixture", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, title, -1, transient)
        sqlite3_bind_text(statement, 3, provider, -1, transient)
        sqlite3_bind_text(statement, 4, model, -1, transient)
        sqlite3_bind_text(statement, 5, rolloutPath, -1, transient)
        sqlite3_bind_int64(statement, 6, sqlite3_int64(updatedAt))
        sqlite3_bind_int(statement, 7, Int32(archived))
        sqlite3_bind_text(statement, 8, source, -1, transient)
        sqlite3_bind_text(statement, 9, threadSource, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "Fixture", code: 4)
        }
    }
}
