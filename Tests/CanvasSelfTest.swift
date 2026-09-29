import AppKit
import Foundation

@main
struct CanvasSelfTest {
    static func main() throws {
        _ = NSApplication.shared
        let parentID = "11111111-1111-7111-8111-111111111111"
        let childID = "22222222-2222-7222-8222-222222222222"
        let annotationID = "annotation-test"
        let board = ConversationBoard(
            id: "board-test",
            workspaceID: "workspace-test",
            name: "测试画板",
            layoutPreset: .vertical,
            nodes: [
                parentID: ConversationTreeNode(x: 320, y: 220),
                childID: ConversationTreeNode(x: 320, y: 440)
            ],
            parentByTaskID: [childID: parentID],
            roots: [parentID: ConversationTreeRootMetadata(name: "主树", note: "树说明")],
            edges: [childID: ConversationEdgeMetadata(title: "继续推进", note: "关系备注")],
            annotations: [
                annotationID: BoardAnnotation(
                    id: annotationID, kind: .group, x: 700, y: 330,
                    width: 360, height: 240, title: "阶段说明", body: "自由说明内容"
                )
            ]
        )
        let view = BoardCanvasNSView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 760))
        view.board = board
        view.tasks = [
            parentID: task(id: parentID, title: "上级会话"),
            childID: task(id: childID, title: "下级会话")
        ]
        view.selection = [.node(parentID), .edge(childID), .annotation(annotationID)]
        view.layoutSubtreeIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw failure("Canvas did not allocate a bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.bitmapData else { throw failure("Canvas bitmap had no pixels") }
        let byteCount = bitmap.bytesPerRow * bitmap.pixelsHigh
        let nonUniform = (1..<byteCount).contains { data[$0] != data[0] }
        guard nonUniform else { throw failure("Canvas rendered as a uniform blank image") }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CodexProviderSwitcher-CanvasSelfTest.png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)

        var selected: Set<BoardSelection> = []
        view.selection = []
        view.onSelection = { selected = $0 }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 460)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 400, y: 460)))
        guard selected == [.node(parentID)] else { throw failure("Node click did not select the node") }

        var moveDelta = CGSize.zero
        view.onMove = { _, delta in moveDelta = delta }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 460)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 440, y: 430)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 440, y: 430)))
        guard moveDelta == CGSize(width: 40, height: 30) else {
            throw failure("Selected-node drag did not report the expected group movement")
        }

        view.tool = .select
        view.selection = []
        selected = []
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 180, y: 580)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 580, y: 180)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 580, y: 180)))
        guard selected.contains(.node(parentID)) && selected.contains(.node(childID)) else {
            throw failure("Marquee selection did not include both conversation nodes")
        }

        var connected: (String, String)?
        view.tool = .connect
        view.onConnect = { connected = ($0, $1) }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 428)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 400, y: 272)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 400, y: 272)))
        guard connected?.0 == parentID && connected?.1 == childID else {
            throw failure("Connector drag did not report the parent-child relationship")
        }

        view.board = ConversationBoard(
            id: "board-horizontal", workspaceID: "workspace-test", name: "横向画板",
            layoutPreset: .horizontal,
            nodes: [
                parentID: ConversationTreeNode(x: 300, y: 250),
                childID: ConversationTreeNode(x: 520, y: 250)
            ],
            parentByTaskID: [childID: parentID],
            roots: [parentID: ConversationTreeRootMetadata(name: "横向树", layoutPreset: .horizontal)]
        )
        connected = nil
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 462, y: 430)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 518, y: 430)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 518, y: 430)))
        guard connected?.0 == parentID && connected?.1 == childID else {
            throw failure("Horizontal connector drag did not use left-right ports")
        }
        print("Canvas self-test passed: \(output.path)")
    }

    private static func task(id: String, title: String) -> CodexTask {
        CodexTask(
            id: id, title: title, preview: "", indexedTitle: nil,
            provider: "custom", model: "test", rolloutPath: "",
            workspacePath: "/fixture", updatedAt: Date(), archived: false,
            threadSource: "user", parentThreadID: nil
        )
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CanvasSelfTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        )!
    }
}
