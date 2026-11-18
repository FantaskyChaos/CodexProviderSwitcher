import Foundation

struct ReplayCompatibility {
    var reasoningItems = 0
    var itemIDs = 0
    var opaqueItems = 0
    var recoverableEncryptedItems = 0
    var largeImages = 0
    var latestFailure: String?

    var repairCount: Int { reasoningItems + itemIDs + recoverableEncryptedItems + largeImages }
    var hasReplayFailure: Bool {
        guard let latestFailure else { return false }
        return ["invalid_encrypted_content", "persisted-item lookup", "Bad Request"]
            .contains { latestFailure.contains($0) }
    }

    mutating func inspect(_ record: [String: Any]) {
        guard let payload = record["payload"] as? [String: Any] else { return }
        if record["type"] as? String == "response_item" {
            inspectItem(payload)
        } else if record["type"] as? String == "compacted" {
            for key in ["replacement_history", "guardian_history"] {
                for item in payload[key] as? [[String: Any]] ?? [] { inspectItem(item) }
            }
        } else if record["type"] as? String == "event_msg",
                  payload["type"] as? String == "task_complete" {
            latestFailure = (payload["error"] as? [String: Any])?["message"] as? String
        }
    }

    private mutating func inspectItem(_ item: [String: Any]) {
        if item["type"] as? String == "reasoning" {
            reasoningItems += 1
            return
        }
        if item["id"] as? String != nil { itemIDs += 1 }
        if let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty {
            if Self.hasPlaintextAlternative(item) {
                recoverableEncryptedItems += 1
            } else {
                opaqueItems += 1
            }
        }
        if Self.isToolOutput(item) {
            largeImages += (item["output"] as? [[String: Any]] ?? []).filter(Self.isLargeImage).count
        }
    }

    // Only replay envelopes are changed; user text, tool outputs and UI events
    // are never recursively interpreted as model response items.
    static func portableRecord(
        _ record: [String: Any],
        archiveImage: ((String) throws -> String)? = nil,
        allowDroppingOpaqueHistory: Bool = false
    ) throws -> [String: Any]? {
        var result = record
        guard var payload = record["payload"] as? [String: Any] else { return record }
        if record["type"] as? String == "response_item" {
            if payload["type"] as? String == "reasoning" {
                let summary = (payload["summary"] as? [[String: Any]] ?? [])
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                result["type"] = "event_msg"
                result["payload"] = ["type": "agent_reasoning", "text": summary]
                result.removeValue(forKey: "metadata")
                return result
            }
            guard let item = try portableItem(
                payload,
                archiveImage: archiveImage,
                allowDroppingOpaqueHistory: allowDroppingOpaqueHistory
            ) else {
                guard allowDroppingOpaqueHistory else { return nil }
                result["type"] = "event_msg"
                result["payload"] = [
                    "type": "agent_reasoning",
                    "text": ""
                ]
                result.removeValue(forKey: "metadata")
                return result
            }
            result["payload"] = item
            if record["metadata"] != nil {
                result["metadata"] = portableMetadata(record["metadata"])
            }
        } else if record["type"] as? String == "compacted" {
            for key in ["replacement_history", "guardian_history"] {
                guard let items = payload[key] as? [[String: Any]] else { continue }
                let metadataKey = key + "_metadata"
                let metadata = payload[metadataKey] as? [Any]
                if let metadata, metadata.count != items.count {
                    throw SwitcherError.invalidData("压缩历史与元数据数量不匹配，已停止修复")
                }
                var newItems: [[String: Any]] = []
                var newMetadata: [Any] = []
                for (index, original) in items.enumerated() {
                    if let item = try portableItem(
                        original,
                        archiveImage: archiveImage,
                        allowDroppingOpaqueHistory: allowDroppingOpaqueHistory
                    ) {
                        newItems.append(item)
                        if let metadata { newMetadata.append(portableMetadata(metadata[index])) }
                    }
                }
                payload[key] = newItems
                if metadata != nil { payload[metadataKey] = newMetadata }
            }
            result["payload"] = payload
        }
        return result
    }

    private static func portableItem(
        _ item: [String: Any],
        archiveImage: ((String) throws -> String)?,
        allowDroppingOpaqueHistory: Bool
    ) throws -> [String: Any]? {
        if item["type"] as? String == "reasoning" { return nil }
        if let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty {
            guard Self.hasPlaintextAlternative(item) else {
                if allowDroppingOpaqueHistory { return nil }
                throw SwitcherError.unsafe("存在没有明文替代内容的加密历史，无法自动修复")
            }
        }
        var result = item
        result.removeValue(forKey: "id")
        result.removeValue(forKey: "encrypted_content")
        if isToolOutput(item), let content = item["output"] as? [[String: Any]] {
            result["output"] = try content.map { part -> [String: Any] in
                guard isLargeImage(part), let url = part["image_url"] as? String else { return part }
                guard let archiveImage else {
                    throw SwitcherError.invalidData("历史图片必须先保存原件，已停止修复")
                }
                let path = try archiveImage(url)
                return ["type": "input_text", "text": "历史工具图片已原样保存到本地：\(path)。需要查看时读取此图片文件。"]
            }
        }
        return result
    }

    private static func hasPlaintextAlternative(_ item: [String: Any]) -> Bool {
        guard item["type"] as? String == "message",
              let content = item["content"] as? [[String: Any]] else { return false }
        return content.contains { part in
            ["input_text", "output_text"].contains(part["type"] as? String ?? "")
                && !(part["text"] as? String ?? "").isEmpty
        }
    }

    private static func isToolOutput(_ item: [String: Any]) -> Bool {
        ["custom_tool_call_output", "function_call_output"].contains(item["type"] as? String ?? "")
    }

    private static func isLargeImage(_ part: [String: Any]) -> Bool {
        part["type"] as? String == "input_image"
            && (part["image_url"] as? String).map { $0.hasPrefix("data:image/") && $0.utf8.count > 1_048_576 } == true
    }

    private static func portableMetadata(_ value: Any?) -> Any {
        guard var metadata = value as? [String: Any] else { return value ?? NSNull() }
        metadata.removeValue(forKey: "retained_source")
        return metadata
    }
}
