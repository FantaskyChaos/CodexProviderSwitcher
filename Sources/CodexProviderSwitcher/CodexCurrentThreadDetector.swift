import AppKit
import ApplicationServices
import Foundation

enum CodexCurrentThreadDetection: Equatable {
    case found(String)
    case codexNotRunning
    case accessibilityPermissionRequired
    case noFocusedThread
    case ambiguousTitle(String)
    case unavailableThread(String)
    case unavailableTitle(String)
}

struct CodexCurrentThreadDetector {
    static let bundleIdentifier = "com.openai.codex"

    let logsRoot: URL

    init(logsRoot: URL? = nil) {
        self.logsRoot = logsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true)
    }

    func detect(
        tasks: [CodexTask],
        processIdentifiers: Set<Int32>? = nil,
        currentTitleOverride: String? = nil,
        accessibilityTrustedOverride: Bool? = nil
    ) -> CodexCurrentThreadDetection {
        let runningPIDs = processIdentifiers ?? Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
                .map(\.processIdentifier)
        )
        guard !runningPIDs.isEmpty else { return .codexNotRunning }

        let knownTitles = Set(tasks.map(\.displayTitle))
        let currentTitle = currentTitleOverride ?? runningPIDs.compactMap {
            currentConversationTitle(processIdentifier: $0, knownTitles: knownTitles)
        }.first
        guard let currentTitle, !currentTitle.isEmpty else {
            if let loggedID = latestFocusedThreadID(for: runningPIDs) {
                if let task = tasks.first(where: { $0.id == loggedID }) {
                    return .found(task.id)
                }
                return .unavailableThread(loggedID)
            }
            if accessibilityTrustedOverride == false ||
                (accessibilityTrustedOverride == nil && !AXIsProcessTrusted()) {
                return .accessibilityPermissionRequired
            }
            return .noFocusedThread
        }

        let matches = tasks.filter {
            !$0.isInternalApprovalReview && $0.displayTitle == currentTitle
        }
        if matches.count == 1, let match = matches.first {
            return .found(match.id)
        }
        if matches.count > 1,
           let loggedID = latestFocusedThreadID(for: runningPIDs),
           matches.contains(where: { $0.id == loggedID }) {
            return .found(loggedID)
        }
        if matches.count > 1 {
            return .ambiguousTitle(currentTitle)
        }
        return .unavailableTitle(currentTitle)
    }

    private func currentConversationTitle(
        processIdentifier: Int32,
        knownTitles: Set<String>
    ) -> String? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedWindowValue: CFTypeRef?
        var windows: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success, let focusedWindowValue {
            windows.append(focusedWindowValue as! AXUIElement)
        }
        if windows.isEmpty {
            var windowListValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &windowListValue
            ) == .success, let windowList = windowListValue as? [AXUIElement] {
                windows = windowList
            }
        }

        for window in windows {
            guard let origin = pointAttribute(kAXPositionAttribute, element: window),
                  let size = sizeAttribute(kAXSizeAttribute, element: window) else { continue }
            let headerFrame = CGRect(
                x: origin.x + 160,
                y: origin.y,
                width: max(0, size.width * 0.68 - 160),
                height: 90
            )
            if let title = findConversationTitle(
                in: window,
                knownTitles: knownTitles,
                headerFrame: headerFrame,
                depth: 0
            ) {
                return title
            }
        }
        return nil
    }

    private func findConversationTitle(
        in element: AXUIElement,
        knownTitles: Set<String>,
        headerFrame: CGRect,
        depth: Int
    ) -> String? {
        guard depth < 40 else { return nil }
        if stringAttribute(kAXRoleAttribute, element: element) == kAXButtonRole,
           let title = stringAttribute(kAXTitleAttribute, element: element),
           knownTitles.contains(title),
           let position = pointAttribute(kAXPositionAttribute, element: element),
           headerFrame.contains(position) {
            return title
        }
        guard let children = attribute(kAXChildrenAttribute, element: element) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let title = findConversationTitle(
                in: child,
                knownTitles: knownTitles,
                headerFrame: headerFrame,
                depth: depth + 1
            ) {
                return title
            }
        }
        return nil
    }

    private func latestFocusedThreadID(for processIdentifiers: Set<Int32>) -> String? {
        var focusedEvents: [FocusedThreadEvent] = []
        for file in logFiles(for: processIdentifiers) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(whereSeparator: \.isNewline) {
                guard let event = FocusedThreadEvent(line: line) else { continue }
                focusedEvents.append(event)
            }
        }
        let explicitEvents = focusedEvents.filter(\.isExplicitSelection)
        return (explicitEvents.isEmpty ? focusedEvents : explicitEvents)
            .max { $0.timestamp < $1.timestamp }?
            .threadID
    }

    private func logFiles(for processIdentifiers: Set<Int32>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: logsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "log",
                  processIdentifiers.contains(where: { url.lastPathComponent.contains("-\($0)-t0-") }),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.modified > $1.modified }.prefix(12).map(\.url)
    }

    private func attribute(_ name: String, element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ name: String, element: AXUIElement) -> String? {
        attribute(name, element: element) as? String
    }

    private func pointAttribute(_ name: String, element: AXUIElement) -> CGPoint? {
        guard let value = attribute(name, element: element), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ name: String, element: AXUIElement) -> CGSize? {
        guard let value = attribute(name, element: element), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}

private struct FocusedThreadEvent {
    let timestamp: String
    let threadID: String
    let isExplicitSelection: Bool

    init?<S: StringProtocol>(line: S) {
        let text = String(line)
        guard text.contains("rendererWindowAppearance=primary"),
              text.contains("rendererWindowFocused=true"),
              text.contains("rendererWindowVisible=true") else { return nil }

        let explicit = text.contains("thread_stream_view_activity_changed active=true")
        let fallback = text.contains("maybe_resume_started")
            || text.contains("Reasoning summary turn-start")
            || text.contains("Reasoning summary item completed")
        guard explicit || fallback else { return nil }

        let id = Self.field("conversationId", in: text) ?? Self.field("threadId", in: text)
        guard let id, !id.isEmpty else { return nil }
        timestamp = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        threadID = id
        isExplicitSelection = explicit
    }

    private static func field(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        let value = line[range.upperBound...].prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}
