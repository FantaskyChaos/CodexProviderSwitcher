import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BoardCanvasRepresentable: NSViewRepresentable {
    let board: ConversationBoard
    let tasks: [String: CodexTask]
    let importantIDs: Set<String>
    let inProgressIDs: Set<String>
    let tool: BoardCanvasTool
    let selection: Set<BoardSelection>
    let fitRequest: Int
    let zoomLevel: Double
    let onSelection: (Set<BoardSelection>) -> Void
    let onMove: (Set<BoardSelection>, CGSize) -> Void
    let onResizeAnnotation: (String, CGRect) -> Void
    let onConnect: (String, String) -> Void
    let canConnect: (String, String) -> Bool
    let onAddAnnotation: (BoardAnnotationKind, CGPoint) -> Void
    let onDropTasks: ([String], CGPoint) -> Void
    let onDelete: (Set<BoardSelection>) -> Void
    let onOpen: (String) -> Void
    let onEdit: (BoardSelection) -> Void
    let onEditEdgeTitle: (String, String) -> Void
    let onMoveEdgeLabel: (String, Double) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onZoomChanged: (Double) -> Void
    let onViewport: (ConversationBoardViewport) -> Void

    func makeNSView(context: Context) -> BoardCanvasNSView {
        let view = BoardCanvasNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: BoardCanvasNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: BoardCanvasNSView) {
        view.board = board
        view.tasks = tasks
        view.importantIDs = importantIDs
        view.inProgressIDs = inProgressIDs
        view.tool = tool
        view.selection = selection
        view.onSelection = onSelection
        view.onMove = onMove
        view.onResizeAnnotation = onResizeAnnotation
        view.onConnect = onConnect
        view.canConnect = canConnect
        view.onAddAnnotation = onAddAnnotation
        view.onDropTasks = onDropTasks
        view.onDelete = onDelete
        view.onOpen = onOpen
        view.onEdit = onEdit
        view.onEditEdgeTitle = onEditEdgeTitle
        view.onMoveEdgeLabel = onMoveEdgeLabel
        view.onUndo = onUndo
        view.onRedo = onRedo
        view.onZoomChanged = onZoomChanged
        view.onViewport = onViewport
        if view.fitRequest != fitRequest {
            view.fitRequest = fitRequest
            view.fitContent()
        } else if abs(view.currentZoom - zoomLevel) > 0.001 {
            view.setZoomLevel(zoomLevel)
        }
        view.needsDisplay = true
    }
}

final class BoardCanvasNSView: NSView, NSTextFieldDelegate {
    var board = ConversationBoard(
        id: "", workspaceID: "", name: "", layoutPreset: .freeform,
        nodes: [:], parentByTaskID: [:]
    ) {
        didSet {
            if board.id != oldValue.id {
                zoom = CGFloat(board.viewport.zoom)
                offset = CGPoint(x: board.viewport.offsetX, y: board.viewport.offsetY)
            }
            needsDisplay = true
        }
    }
    var tasks: [String: CodexTask] = [:]
    var importantIDs: Set<String> = []
    var inProgressIDs: Set<String> = []
    var tool: BoardCanvasTool = .select { didSet { updateCursor() } }
    var selection: Set<BoardSelection> = [] { didSet { needsDisplay = true } }
    var fitRequest = 0

    var onSelection: ((Set<BoardSelection>) -> Void)?
    var onMove: ((Set<BoardSelection>, CGSize) -> Void)?
    var onResizeAnnotation: ((String, CGRect) -> Void)?
    var onConnect: ((String, String) -> Void)?
    var canConnect: ((String, String) -> Bool)?
    var onAddAnnotation: ((BoardAnnotationKind, CGPoint) -> Void)?
    var onDropTasks: (([String], CGPoint) -> Void)?
    var onDelete: ((Set<BoardSelection>) -> Void)?
    var onOpen: ((String) -> Void)?
    var onEdit: ((BoardSelection) -> Void)?
    var onEditEdgeTitle: ((String, String) -> Void)?
    var onMoveEdgeLabel: ((String, Double) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onZoomChanged: ((Double) -> Void)?
    var onViewport: ((ConversationBoardViewport) -> Void)?

    private let nodeSize = CGSize(width: 164, height: 64)
    private var zoom: CGFloat = 1
    private var offset = CGPoint(x: 80, y: 80)
    private var marqueeStart: CGPoint?
    private var marqueeCurrent: CGPoint?
    private var marqueeBaseSelection: Set<BoardSelection> = []
    private var draggingObjects = false
    private var dragStartWorld: CGPoint?
    private var liveDelta = CGSize.zero
    private var panning = false
    private var panStartScreen: CGPoint?
    private var panStartOffset: CGPoint?
    private var spaceHeld = false
    private var connectingParentID: String?
    private var connectionPoint: CGPoint?
    private var resizingAnnotationID: String?
    private var resizeStartFrame: CGRect?
    private var resizeStartWorld: CGPoint?
    private var resizePreviewFrame: CGRect?
    private var draggingEdgeChildID: String?
    private var edgeDragStartWorld: CGPoint?
    private var edgeStartOffset: Double = 0
    private var liveEdgeOffset: Double?
    private var editingEdgeChildID: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.string])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: zoom, y: zoom)
        drawGrid(context)
        drawTreeBoundaries(context)
        drawAnnotations(context)
        drawEdges(context)
        drawNodes(context)
        drawInteraction(context)
        context.restoreGState()
        drawMinimap(context)
    }

    private func drawGrid(_ context: CGContext) {
        guard board.gridEnabled else { return }
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1 / zoom)
        let visible = visibleWorldRect.insetBy(dx: -80, dy: -80)
        let spacing: CGFloat = 40
        var x = floor(visible.minX / spacing) * spacing
        while x <= visible.maxX {
            context.move(to: CGPoint(x: x, y: visible.minY))
            context.addLine(to: CGPoint(x: x, y: visible.maxY))
            x += spacing
        }
        var y = floor(visible.minY / spacing) * spacing
        while y <= visible.maxY {
            context.move(to: CGPoint(x: visible.minX, y: y))
            context.addLine(to: CGPoint(x: visible.maxX, y: y))
            y += spacing
        }
        context.strokePath()

        let pointSpacingX = CGFloat(max(40, board.gridSpacingX))
        let pointSpacingY = CGFloat(max(40, board.gridSpacingY))
        let radius = 2.2 / zoom
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor)
        var pointX = floor(visible.minX / pointSpacingX) * pointSpacingX
        while pointX <= visible.maxX {
            var pointY = floor(visible.minY / pointSpacingY) * pointSpacingY
            while pointY <= visible.maxY {
                context.fillEllipse(in: CGRect(x: pointX - radius, y: pointY - radius,
                                               width: radius * 2, height: radius * 2))
                pointY += pointSpacingY
            }
            pointX += pointSpacingX
        }
    }

    private func drawAnnotations(_ context: CGContext) {
        for annotation in board.annotations.values.sorted(by: { $0.id < $1.id }) {
            let frame = (resizingAnnotationID == annotation.id ? resizePreviewFrame : nil)
                ?? annotationFrame(annotation).offsetBy(dx: liveOffset(for: .annotation(annotation.id)).width,
                                                        dy: liveOffset(for: .annotation(annotation.id)).height)
            let selected = selection.contains(.annotation(annotation.id))
            if annotation.kind == .group {
                let path = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.035).cgColor)
                context.addPath(path); context.fillPath()
                context.setStrokeColor((selected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor)
                context.setLineWidth((selected ? 2 : 1) / zoom)
                context.setLineDash(phase: 0, lengths: [8 / zoom, 5 / zoom])
                context.addPath(path); context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            } else {
                context.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.92).cgColor)
                context.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.fillPath()
                if selected {
                    context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    context.setLineWidth(2 / zoom)
                    context.stroke(frame)
                }
            }
            drawText(annotation.title, in: frame.insetBy(dx: 12, dy: 10),
                     font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
            if !annotation.body.isEmpty {
                drawText(annotation.body, in: frame.insetBy(dx: 12, dy: 34),
                         font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
            }
            if selected {
                let handle = resizeHandle(for: frame)
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.fillEllipse(in: handle)
            }
        }
    }

    private func drawTreeBoundaries(_ context: CGContext) {
        for rootID in rootIDs {
            guard let bounds = treeBounds(rootID) else { continue }
            let selected = selection.contains(.tree(rootID))
            if selected {
                let path = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
                context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
                context.setLineWidth(1.5 / zoom)
                context.setLineDash(phase: 0, lengths: [5 / zoom, 4 / zoom])
                context.addPath(path); context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
            let metadata = board.roots[rootID] ?? ConversationTreeRootMetadata(name: taskTitle(rootID))
            let header = treeHeaderRect(rootID)
            drawText(metadata.name, in: header,
                     font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor)
        }
    }

    private func drawEdges(_ context: CGContext) {
        for (childID, parentID) in board.parentByTaskID.sorted(by: { $0.key < $1.key }) {
            guard visibleNodeIDs.contains(childID), visibleNodeIDs.contains(parentID),
                  let path = edgePath(childID: childID, parentID: parentID) else { continue }
            let selected = selection.contains(.edge(childID))
            context.setStrokeColor((selected ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.68)).cgColor)
            context.setLineWidth((selected ? 3.2 : 2.1) / zoom)
            context.addPath(path); context.strokePath()
            if let metadata = board.edges[childID], !metadata.title.isEmpty {
                let center = edgeLabelPoint(
                    childID: childID,
                    parentID: parentID,
                    offset: draggingEdgeChildID == childID ? (liveEdgeOffset ?? metadata.labelOffset) : metadata.labelOffset
                )
                let size = textSize(metadata.title, font: .systemFont(ofSize: 11, weight: .medium))
                let rect = CGRect(x: center.x - size.width / 2 - 7, y: center.y - 11,
                                  width: size.width + 14, height: 22)
                context.setFillColor(NSColor.controlBackgroundColor.cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)); context.fillPath()
                context.setStrokeColor(NSColor.separatorColor.cgColor); context.setLineWidth(1 / zoom)
                context.stroke(rect)
                drawText(metadata.title, in: rect.insetBy(dx: 7, dy: 4),
                         font: .systemFont(ofSize: 11, weight: .medium), color: .labelColor)
            }
        }
    }

    private func drawNodes(_ context: CGContext) {
        for id in visibleNodeIDs.sorted() {
            guard let task = tasks[id] else { continue }
            let frame = displayNodeFrame(id)
            let selected = selection.contains(.node(id))
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 1 / zoom), blur: selected ? 6 / zoom : 2 / zoom,
                              color: NSColor.black.withAlphaComponent(selected ? 0.18 : 0.08).cgColor)
            context.setFillColor((task.archived ? NSColor.underPageBackgroundColor : NSColor.controlBackgroundColor).cgColor)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)); context.fillPath()
            context.restoreGState()
            context.setStrokeColor((selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor)
            context.setLineWidth((selected ? 2.5 : 1) / zoom)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)); context.strokePath()
            let overview = zoom < 0.78
            let titleFontSize: CGFloat = overview ? 9.5 / zoom : 11
            drawText(task.displayTitle,
                     in: overview
                        ? CGRect(x: frame.minX + 8, y: frame.minY + 8, width: frame.width - 16, height: frame.height - 16)
                        : CGRect(x: frame.minX + 10, y: frame.minY + 8, width: frame.width - 32, height: 29),
                     font: .systemFont(ofSize: titleFontSize, weight: .semibold),
                     color: .labelColor, wraps: !overview)
            let provider = ProviderOption.displayName(for: task.provider)
            if !overview {
                drawText(provider, in: CGRect(x: frame.minX + 10, y: frame.maxY - 19, width: 108, height: 13),
                         font: .systemFont(ofSize: 8.5, weight: .medium),
                         color: task.provider == "openai" ? .systemBlue : .systemPurple)
            }
            if importantIDs.contains(id) {
                drawText("★", in: CGRect(x: frame.maxX - 22, y: frame.minY + 7, width: 14, height: 14),
                         font: .systemFont(ofSize: overview ? 9 / zoom : 10), color: .systemOrange)
            }
            if inProgressIDs.contains(id) {
                context.setFillColor(NSColor.systemBlue.cgColor)
                context.fillEllipse(in: CGRect(x: frame.maxX - 17, y: frame.maxY - 16, width: 6, height: 6))
            }
            drawPort(context, point: displayInputPort(id), active: false)
            drawPort(context, point: displayOutputPort(id), active: connectingParentID == id)
        }
    }

    private func drawPort(_ context: CGContext, point: CGPoint, active: Bool) {
        let radius: CGFloat = (active ? 6 : 4) / zoom
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor((active ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.82)).cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.controlBackgroundColor.cgColor)
        context.setLineWidth(1.5 / zoom); context.strokeEllipse(in: rect)
    }

    private func drawInteraction(_ context: CGContext) {
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = normalizedRect(start, current)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5 / zoom); context.stroke(rect)
        }
        if let parentID = connectingParentID, let point = connectionPoint {
            let start = outputPort(parentID)
            let path = CGMutablePath(); path.move(to: start)
            if nodeLayoutPreset(parentID) == .horizontal {
                let middle = (start.x + point.x) / 2
                path.addCurve(to: point, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: point.y))
            } else {
                let middle = (start.y + point.y) / 2
                path.addCurve(to: point, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: point.x, y: middle))
            }
            let candidate = hitInputPort(point) ?? hitNode(point)
            let valid = candidate.map { canConnect?(parentID, $0) ?? true } ?? true
            context.setStrokeColor((valid ? NSColor.controlAccentColor : NSColor.systemRed).cgColor)
            context.setLineWidth(2.5 / zoom); context.addPath(path); context.strokePath()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let screen = convert(event.locationInWindow, from: nil)
        let world = worldPoint(screen)
        if minimapRect.contains(screen) {
            navigateFromMinimap(screen)
            return
        }
        if tool == .hand || spaceHeld || event.buttonNumber == 2 {
            panning = true; panStartScreen = screen; panStartOffset = offset
            return
        }
        if tool == .text || tool == .group {
            onAddAnnotation?(tool == .text ? .text : .group, world)
            return
        }
        if tool == .connect || hitOutputPort(world) != nil {
            if let id = hitOutputPort(world) ?? hitNode(world) {
                connectingParentID = id; connectionPoint = world; needsDisplay = true
            }
            return
        }

        let hit = hitSelection(world)
        let additive = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        if event.clickCount == 2, let hit {
            if case .node(let id) = hit { onOpen?(id) }
            else if case .edge(let childID) = hit { beginInlineEdgeEditing(childID) }
            else { onEdit?(hit) }
            return
        }
        if let annotationID = hitResizeHandle(world) {
            resizingAnnotationID = annotationID
            resizeStartFrame = board.annotations[annotationID].map(annotationFrame)
            resizeStartWorld = world
            return
        }
        if let hit {
            var next = selection
            if additive {
                if next.contains(hit) { next.remove(hit) } else { next.insert(hit) }
            } else if !next.contains(hit) {
                next = [hit]
            }
            selection = next; onSelection?(next)
            if case .edge(let childID) = hit, hitEdgeLabel(world) == childID {
                draggingEdgeChildID = childID
                edgeDragStartWorld = world
                edgeStartOffset = board.edges[childID]?.labelOffset ?? 0
                return
            }
            draggingObjects = true; dragStartWorld = world; liveDelta = .zero
        } else {
            if !additive { selection = []; onSelection?([]) }
            marqueeBaseSelection = additive ? selection : []
            marqueeStart = world; marqueeCurrent = world
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let screen = convert(event.locationInWindow, from: nil)
        let world = worldPoint(screen)
        if panning, let start = panStartScreen, let initial = panStartOffset {
            offset = CGPoint(x: initial.x + screen.x - start.x, y: initial.y + screen.y - start.y)
            needsDisplay = true; return
        }
        if connectingParentID != nil { connectionPoint = world; needsDisplay = true; return }
        if let childID = draggingEdgeChildID,
           let start = edgeDragStartWorld,
           let parentID = board.parentByTaskID[childID] {
            let a = outputPort(parentID), b = inputPort(childID)
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = max(1, dx * dx + dy * dy)
            let shift = Double(((world.x - start.x) * dx + (world.y - start.y) * dy) / lengthSquared)
            liveEdgeOffset = max(-0.35, min(0.35, edgeStartOffset + shift))
            needsDisplay = true; return
        }
        if resizingAnnotationID != nil, let start = resizeStartWorld, let frame = resizeStartFrame {
            resizePreviewFrame = CGRect(x: frame.minX, y: frame.minY,
                                        width: max(120, frame.width + world.x - start.x),
                                        height: max(70, frame.height + world.y - start.y))
            needsDisplay = true
            return
        }
        if draggingObjects, let start = dragStartWorld {
            liveDelta = CGSize(width: world.x - start.x, height: world.y - start.y)
            needsDisplay = true; return
        }
        if marqueeStart != nil { marqueeCurrent = world; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let world = worldPoint(convert(event.locationInWindow, from: nil))
        if panning { panning = false; persistViewport(); return }
        if let parent = connectingParentID {
            if let child = hitInputPort(world) ?? hitNode(world),
               child != parent,
               canConnect?(parent, child) ?? true {
                onConnect?(parent, child)
            }
            connectingParentID = nil; connectionPoint = nil; needsDisplay = true; return
        }
        if let id = resizingAnnotationID, let frame = resizePreviewFrame {
            onResizeAnnotation?(id, frame)
            resizingAnnotationID = nil; resizePreviewFrame = nil
            resizeStartFrame = nil; resizeStartWorld = nil
            needsDisplay = true; return
        }
        if let childID = draggingEdgeChildID {
            onMoveEdgeLabel?(childID, liveEdgeOffset ?? edgeStartOffset)
            draggingEdgeChildID = nil; edgeDragStartWorld = nil; liveEdgeOffset = nil
            needsDisplay = true; return
        }
        if draggingObjects {
            if abs(liveDelta.width) > 0.5 || abs(liveDelta.height) > 0.5 { onMove?(selection, liveDelta) }
            draggingObjects = false; dragStartWorld = nil; liveDelta = .zero; needsDisplay = true; return
        }
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = normalizedRect(start, current)
            var next: Set<BoardSelection> = []
            for id in visibleNodeIDs where rect.intersects(nodeFrame(id)) { next.insert(.node(id)) }
            for item in board.annotations.values where rect.intersects(annotationFrame(item)) { next.insert(.annotation(item.id)) }
            for root in rootIDs where rect.intersects(treeHeaderRect(root)) { next.insert(.tree(root)) }
            for (child,parent) in board.parentByTaskID where rect.contains(edgeLabelPoint(childID: child, parentID: parent, offset: board.edges[child]?.labelOffset ?? 0)) {
                next.insert(.edge(child))
            }
            next.formUnion(marqueeBaseSelection)
            selection = next; onSelection?(next)
        }
        marqueeStart = nil; marqueeCurrent = nil; marqueeBaseSelection = []; needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            setZoom(zoom * (1 - event.scrollingDeltaY * 0.012), anchoredAt: point)
        } else {
            offset.x += event.scrollingDeltaX
            offset.y += event.scrollingDeltaY
            needsDisplay = true
        }
        persistViewport()
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchoredAt: convert(event.locationInWindow, from: nil))
        persistViewport()
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if command, event.charactersIgnoringModifiers == "a" {
            var all = Set(visibleNodeIDs.map(BoardSelection.node))
            all.formUnion(board.annotations.keys.map(BoardSelection.annotation))
            selection = all; onSelection?(all); needsDisplay = true; return
        }
        if command, event.charactersIgnoringModifiers == "z" {
            shift ? onRedo?() : onUndo?(); return
        }
        if event.keyCode == 49 { spaceHeld = true; updateCursor(); return }
        if event.keyCode == 53 { selection = []; onSelection?([]); needsDisplay = true; return }
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(selection); return }
        let step: CGFloat = shift ? 10 : 1
        let delta: CGSize?
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        case 126: delta = CGSize(width: 0, height: -step)
        default: delta = nil
        }
        if let delta { onMove?(selection, delta) } else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; updateCursor() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = sender.draggingPasteboard.string(forType: .string) else { return false }
        let ids = payload.split(whereSeparator: \Character.isNewline).map(String.init)
        guard !ids.isEmpty else { return false }
        onDropTasks?(ids, worldPoint(convert(sender.draggingLocation, from: nil)))
        return true
    }

    func fitContent() {
        let content = contentBounds
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        zoom = min(1, max(0.6, min((bounds.width - 70) / content.width, (bounds.height - 70) / content.height)))
        offset = CGPoint(x: (bounds.width - content.width * zoom) / 2 - content.minX * zoom,
                         y: (bounds.height - content.height * zoom) / 2 - content.minY * zoom)
        persistViewport(); needsDisplay = true
    }

    func adjustZoom(_ factor: CGFloat) {
        setZoom(zoom * factor, anchoredAt: CGPoint(x: bounds.midX, y: bounds.midY))
        persistViewport()
    }

    var currentZoom: Double { Double(zoom) }

    func setZoomLevel(_ value: Double) {
        setZoom(CGFloat(value), anchoredAt: CGPoint(x: bounds.midX, y: bounds.midY))
        persistViewport()
    }

    private var rootIDs: [String] {
        BoardGraph.roots(nodeIDs: Set(board.nodes.keys), parentByTaskID: board.parentByTaskID)
    }

    private var visibleNodeIDs: Set<String> {
        var visible = Set(board.nodes.keys).intersection(tasks.keys)
        for root in rootIDs where board.roots[root]?.isCollapsed == true {
            visible.subtract(BoardGraph.descendants(of: root, parentByTaskID: board.parentByTaskID).subtracting([root]))
        }
        return visible
    }

    private var visibleWorldRect: CGRect {
        CGRect(x: -offset.x / zoom, y: -offset.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    private var contentBounds: CGRect {
        var result = CGRect.null
        for id in visibleNodeIDs { result = result.union(nodeFrame(id)) }
        for item in board.annotations.values { result = result.union(annotationFrame(item)) }
        return result.isNull ? CGRect(x: 0, y: 0, width: 800, height: 600) : result.insetBy(dx: -35, dy: -40)
    }

    private func nodeFrame(_ id: String) -> CGRect {
        guard let node = board.nodes[id] else { return .zero }
        return CGRect(x: node.x - nodeSize.width / 2, y: node.y - nodeSize.height / 2,
                      width: nodeSize.width, height: nodeSize.height)
    }

    private func displayNodeFrame(_ id: String) -> CGRect {
        let delta = liveOffset(for: .node(id))
        return nodeFrame(id).offsetBy(dx: delta.width, dy: delta.height)
    }

    private func annotationFrame(_ item: BoardAnnotation) -> CGRect {
        CGRect(x: item.x - item.width / 2, y: item.y - item.height / 2, width: item.width, height: item.height)
    }

    private func treeBounds(_ rootID: String) -> CGRect? {
        let ids = BoardGraph.descendants(of: rootID, parentByTaskID: board.parentByTaskID).intersection(visibleNodeIDs)
        var rect = CGRect.null
        for id in ids { rect = rect.union(nodeFrame(id).offsetBy(dx: liveOffset(for: .node(id)).width, dy: liveOffset(for: .node(id)).height)) }
        return rect.isNull ? nil : rect.insetBy(dx: -10, dy: -16).offsetBy(dx: 0, dy: 3)
    }

    private func treeHeaderRect(_ rootID: String) -> CGRect {
        guard let bounds = treeBounds(rootID) else { return .zero }
        return CGRect(x: bounds.minX + 4, y: bounds.minY - 11, width: min(140, bounds.width - 8), height: 18)
    }

    private func inputPort(_ id: String) -> CGPoint {
        let frame = nodeFrame(id)
        return nodeLayoutPreset(id) == .horizontal
            ? CGPoint(x: frame.minX, y: frame.midY)
            : CGPoint(x: frame.midX, y: frame.minY)
    }

    private func outputPort(_ id: String) -> CGPoint {
        let frame = nodeFrame(id)
        return nodeLayoutPreset(id) == .horizontal
            ? CGPoint(x: frame.maxX, y: frame.midY)
            : CGPoint(x: frame.midX, y: frame.maxY)
    }

    private func displayInputPort(_ id: String) -> CGPoint {
        let frame = displayNodeFrame(id)
        return nodeLayoutPreset(id) == .horizontal
            ? CGPoint(x: frame.minX, y: frame.midY)
            : CGPoint(x: frame.midX, y: frame.minY)
    }

    private func displayOutputPort(_ id: String) -> CGPoint {
        let frame = displayNodeFrame(id)
        return nodeLayoutPreset(id) == .horizontal
            ? CGPoint(x: frame.maxX, y: frame.midY)
            : CGPoint(x: frame.midX, y: frame.maxY)
    }

    private func edgePath(childID: String, parentID: String) -> CGPath? {
        guard board.nodes[childID] != nil, board.nodes[parentID] != nil else { return nil }
        let start = displayOutputPort(parentID), end = displayInputPort(childID)
        let path = CGMutablePath(); path.move(to: start)
        if board.gridEnabled {
            if edgeLayoutPreset(childID: childID, parentID: parentID) == .horizontal {
                let middle = (start.x + end.x) / 2
                path.addLine(to: CGPoint(x: middle, y: start.y))
                path.addLine(to: CGPoint(x: middle, y: end.y))
            } else {
                let middle = (start.y + end.y) / 2
                path.addLine(to: CGPoint(x: start.x, y: middle))
                path.addLine(to: CGPoint(x: end.x, y: middle))
            }
            path.addLine(to: end)
            return path
        }
        if edgeLayoutPreset(childID: childID, parentID: parentID) == .horizontal {
            let middle = (start.x + end.x) / 2
            path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
        } else {
            let middle = (start.y + end.y) / 2
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
        }
        return path
    }

    private func edgeLabelPoint(childID: String, parentID: String, offset: Double) -> CGPoint {
        let start = displayOutputPort(parentID), end = displayInputPort(childID)
        let t = CGFloat(0.5 + offset)
        return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
    }

    private func hitSelection(_ point: CGPoint) -> BoardSelection? {
        if let node = hitNode(point) { return .node(node) }
        if let item = board.annotations.values.sorted(by: { $0.kind == .text && $1.kind == .group }).first(where: { annotationFrame($0).contains(point) }) {
            return .annotation(item.id)
        }
        for (child,parent) in board.parentByTaskID {
            let label = edgeLabelPoint(childID: child, parentID: parent, offset: board.edges[child]?.labelOffset ?? 0)
            if hypot(point.x - label.x, point.y - label.y) < 24 || distanceToEdge(point, child: child, parent: parent) < 8 / zoom {
                return .edge(child)
            }
        }
        if let root = rootIDs.first(where: { treeHeaderRect($0).contains(point) }) { return .tree(root) }
        return nil
    }

    private func hitEdgeLabel(_ point: CGPoint) -> String? {
        for (child, parent) in board.parentByTaskID {
            guard let metadata = board.edges[child], !metadata.title.isEmpty else { continue }
            let center = edgeLabelPoint(childID: child, parentID: parent, offset: metadata.labelOffset)
            let size = textSize(metadata.title, font: .systemFont(ofSize: 11, weight: .medium))
            let rect = CGRect(x: center.x - size.width / 2 - 9, y: center.y - 13, width: size.width + 18, height: 26)
            if rect.contains(point) { return child }
        }
        return nil
    }

    private func hitNode(_ point: CGPoint) -> String? {
        visibleNodeIDs.sorted().reversed().first { nodeFrame($0).insetBy(dx: -3, dy: -3).contains(point) }
    }

    private func hitOutputPort(_ point: CGPoint) -> String? {
        visibleNodeIDs.first { hypot(point.x - outputPort($0).x, point.y - outputPort($0).y) < 13 / zoom }
    }

    private func hitInputPort(_ point: CGPoint) -> String? {
        visibleNodeIDs.first { hypot(point.x - inputPort($0).x, point.y - inputPort($0).y) < 15 / zoom }
    }

    private func hitResizeHandle(_ point: CGPoint) -> String? {
        selection.compactMap { if case .annotation(let id) = $0 { id } else { nil } }.first {
            guard let item = board.annotations[$0] else { return false }
            return resizeHandle(for: annotationFrame(item)).insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    private func resizeHandle(for frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - 6, y: frame.maxY - 6, width: 12, height: 12)
    }

    private func distanceToEdge(_ point: CGPoint, child: String, parent: String) -> CGFloat {
        let start = outputPort(parent), end = inputPort(child)
        var minimum = CGFloat.greatestFiniteMagnitude
        var previous = start
        for i in 1...24 {
            let t = CGFloat(i) / 24
            let current: CGPoint
            if edgeLayoutPreset(childID: child, parentID: parent) == .horizontal {
                let middle = (start.x + end.x) / 2
                current = cubic(start, CGPoint(x: middle, y: start.y), CGPoint(x: middle, y: end.y), end, t)
            } else {
                let middle = (start.y + end.y) / 2
                current = cubic(start, CGPoint(x: start.x, y: middle), CGPoint(x: end.x, y: middle), end, t)
            }
            minimum = min(minimum, distance(point, toSegmentFrom: previous, to: current)); previous = current
        }
        return minimum
    }

    private func nodeLayoutPreset(_ id: String) -> ConversationTreeLayoutPreset {
        let rootID = BoardGraph.root(of: id, parentByTaskID: board.parentByTaskID)
        if let preset = board.roots[rootID]?.layoutPreset, preset != .freeform { return preset }
        if board.layoutPreset != .freeform { return board.layoutPreset }
        if let parentID = board.parentByTaskID[id],
           let node = board.nodes[id], let parent = board.nodes[parentID] {
            return abs(node.x - parent.x) >= abs(node.y - parent.y) ? .horizontal : .vertical
        }
        if let childID = board.parentByTaskID.first(where: { $0.value == id })?.key,
           let node = board.nodes[id], let child = board.nodes[childID] {
            return abs(child.x - node.x) >= abs(child.y - node.y) ? .horizontal : .vertical
        }
        return .horizontal
    }

    private func edgeLayoutPreset(childID: String, parentID: String) -> ConversationTreeLayoutPreset {
        let preset = nodeLayoutPreset(childID)
        if preset != .freeform { return preset }
        guard let child = board.nodes[childID], let parent = board.nodes[parentID] else { return .horizontal }
        return abs(child.x - parent.x) >= abs(child.y - parent.y) ? .horizontal : .vertical
    }

    private func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let m = 1 - t
        return CGPoint(x: m*m*m*p0.x + 3*m*m*t*p1.x + 3*m*t*t*p2.x + t*t*t*p3.x,
                       y: m*m*m*p0.y + 3*m*m*t*p1.y + 3*m*t*t*p2.y + t*t*t*p3.y)
    }

    private func distance(_ p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x-a.x, dy = b.y-a.y
        if dx == 0 && dy == 0 { return hypot(p.x-a.x,p.y-a.y) }
        let t = max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/(dx*dx+dy*dy)))
        return hypot(p.x-(a.x+t*dx),p.y-(a.y+t*dy))
    }

    private func liveOffset(for item: BoardSelection) -> CGSize {
        if selection.contains(item) { return liveDelta }
        if case .node(let id) = item {
            for selected in selection {
                if case .tree(let rootID) = selected,
                   BoardGraph.descendants(of: rootID, parentByTaskID: board.parentByTaskID).contains(id) {
                    return liveDelta
                }
            }
        }
        return .zero
    }
    private func worldPoint(_ screen: CGPoint) -> CGPoint { CGPoint(x: (screen.x-offset.x)/zoom, y: (screen.y-offset.y)/zoom) }
    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }

    private func setZoom(_ proposed: CGFloat, anchoredAt screen: CGPoint) {
        let before = worldPoint(screen)
        zoom = min(1.6, max(0.6, proposed))
        offset = CGPoint(x: screen.x - before.x*zoom, y: screen.y - before.y*zoom)
        needsDisplay = true
    }

    private func persistViewport() {
        onZoomChanged?(Double(zoom))
        onViewport?(ConversationBoardViewport(offsetX: offset.x, offsetY: offset.y, zoom: zoom))
    }

    private func updateCursor() {
        if tool == .hand || spaceHeld { NSCursor.openHand.set() }
        else if tool == .connect { NSCursor.crosshair.set() }
        else { NSCursor.arrow.set() }
    }

    private func beginInlineEdgeEditing(_ childID: String) {
        guard let parentID = board.parentByTaskID[childID] else { return }
        subviews.compactMap { $0 as? NSTextField }.forEach { $0.removeFromSuperview() }
        let metadata = board.edges[childID] ?? ConversationEdgeMetadata()
        let world = edgeLabelPoint(childID: childID, parentID: parentID, offset: metadata.labelOffset)
        let screen = CGPoint(x: world.x * zoom + offset.x, y: world.y * zoom + offset.y)
        let field = NSTextField(string: metadata.title)
        field.placeholderString = "关系标题"
        field.frame = CGRect(x: screen.x - 90, y: screen.y - 14, width: 180, height: 28)
        field.delegate = self
        field.target = self
        field.action = #selector(commitInlineEdgeEditing(_:))
        editingEdgeChildID = childID
        addSubview(field)
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc private func commitInlineEdgeEditing(_ sender: NSTextField) {
        guard let childID = editingEdgeChildID else { return }
        onEditEdgeTitle?(childID, sender.stringValue)
        editingEdgeChildID = nil
        sender.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, editingEdgeChildID != nil else { return }
        commitInlineEdgeEditing(field)
    }

    private func taskTitle(_ id: String) -> String { tasks[id]?.displayTitle ?? id }

    private func drawText(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, wraps: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        NSString(string: string).draw(in: rect, withAttributes: [.font:font,.foregroundColor:color,.paragraphStyle:paragraph])
    }

    private func textSize(_ string: String, font: NSFont) -> CGSize {
        NSString(string: string).size(withAttributes: [.font:font])
    }

    private var minimapRect: CGRect { CGRect(x: max(12,bounds.width-158), y: max(12,bounds.height-104), width: 146, height: 92) }

    private func drawMinimap(_ context: CGContext) {
        let frame = minimapRect
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.fillPath()
        context.setStrokeColor(NSColor.separatorColor.cgColor); context.setLineWidth(1); context.stroke(frame)
        let content = contentBounds
        let scale = min((frame.width-16)/max(1,content.width),(frame.height-16)/max(1,content.height))
        func mini(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX+8+(p.x-content.minX)*scale, y: frame.minY+8+(p.y-content.minY)*scale) }
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor)
        for id in visibleNodeIDs {
            let r = nodeFrame(id), p = mini(r.origin)
            context.fill(CGRect(x:p.x,y:p.y,width:max(3,r.width*scale),height:max(2,r.height*scale)))
        }
        let view = visibleWorldRect, vp = mini(view.origin)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5)
        context.stroke(CGRect(x:vp.x,y:vp.y,width:view.width*scale,height:view.height*scale))
    }

    private func navigateFromMinimap(_ point: CGPoint) {
        let frame = minimapRect, content = contentBounds
        let scale = min((frame.width-16)/max(1,content.width),(frame.height-16)/max(1,content.height))
        let world = CGPoint(x: content.minX+(point.x-frame.minX-8)/scale, y: content.minY+(point.y-frame.minY-8)/scale)
        offset = CGPoint(x: bounds.midX-world.x*zoom, y: bounds.midY-world.y*zoom)
        persistViewport(); needsDisplay = true
    }
}
