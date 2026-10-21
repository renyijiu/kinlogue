import Foundation
import KinlogueAssistantIPC

/// Follows the JSONL events of `codex exec --json`. The answer is the last agent message, and only
/// once the turn has completed. Any item other than a message, reasoning or an error notice means a
/// tool ran despite the hardening, and the turn is stopped.
public struct CodexEventAccumulator: Sendable {
    static let allowedItemTypes: Set<String> = ["agent_message", "reasoning", "error"]

    public private(set) var threadStarted = false
    public private(set) var turnCompleted = false
    public private(set) var failureMessage: String?
    private var lastMessage: String?

    public init() {}

    public var answer: String? { turnCompleted ? lastMessage : nil }

    public mutating func consume(_ line: Data) throws {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = event["type"] as? String else {
            throw CodexAdapterError.malformedOutput
        }
        switch type {
        case "thread.started":
            threadStarted = true
        case "turn.completed":
            turnCompleted = true
        case "turn.failed":
            failureMessage = (event["error"] as? [String: Any])?["message"] as? String ?? ""
        case "error":
            failureMessage = event["message"] as? String ?? ""
        case "item.started", "item.updated", "item.completed":
            guard let item = event["item"] as? [String: Any], let itemType = item["type"] as? String else {
                throw CodexAdapterError.malformedOutput
            }
            guard Self.allowedItemTypes.contains(itemType) else { throw CodexAdapterError.toolUseDetected }
            if type == "item.completed", itemType == "agent_message", let text = item["text"] as? String {
                lastMessage = text
            }
        default:
            // New top-level events carry no answer; items are where tools would show up.
            break
        }
    }
}

/// Maps the CLI's failure text to a semantic code. The text itself is dropped. The patterns are
/// what the CLI and its provider are known to print; anything else is a plain failure.
public enum CodexFailureClassifier {
    public static func code(for message: String?, exitStatus: Int32) -> KinlogueAssistantFailureCode {
        let text = (message ?? "").lowercased()
        if ["401", "unauthorized", "not logged in", "codex login"].contains(where: text.contains) {
            return .notLoggedIn
        }
        if ["429", "rate limit", "usage limit", "too many requests", "quota"].contains(where: text.contains) {
            return .rateLimited
        }
        if ["stream disconnected", "error sending request", "connection", "network", "dns"].contains(where: text.contains) {
            return .networkUnavailable
        }
        return .failed
    }
}

public enum CodexRequestViolation: Equatable, Sendable {
    case notJSON
    case toolsAdvertised([String])
    /// The input is not exactly our instructions followed by our stdin text.
    case unexpectedInput
    case storeEnabled
    /// The request named a different model from the one checked.
    case unexpectedModel
    case forbiddenText(String)
}

/// Checks one request that Codex sent to the loopback stand-in during the capability check: no
/// tool of any kind, only our two messages, no server-side storage, and none of the local strings
/// (home folder, user name, working directory) that would show the CLI added context of its own.
public enum CodexRequestInspection {
    public static func violations(
        in body: Data,
        instructions: String,
        input: String,
        forbiddenText: [String],
        model: String? = nil
    ) -> [CodexRequestViolation] {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return [.notJSON] }
        var violations: [CodexRequestViolation] = []

        var tools = toolNames(request["tools"] as? [[String: Any]] ?? [])
        let items = request["input"] as? [[String: Any]] ?? []
        for item in items where item["type"] as? String == "additional_tools" {
            tools += toolNames(item["tools"] as? [[String: Any]] ?? [])
        }
        if !tools.isEmpty { violations.append(.toolsAdvertised(tools)) }

        let others = items.filter { $0["type"] as? String != "additional_tools" }
        let expected = [("developer", instructions), ("user", input)]
        let matches = others.count == expected.count && zip(others, expected).allSatisfy { item, pair in
            item["type"] as? String == "message" && item["role"] as? String == pair.0 && text(of: item) == pair.1
        }
        if !matches { violations.append(.unexpectedInput) }

        if request["store"] as? Bool != false { violations.append(.storeEnabled) }
        if let model, request["model"] as? String != model { violations.append(.unexpectedModel) }

        // Decoded strings, not raw bytes: JSON may write "/" as "\/".
        let strings = allStrings(in: request)
        for forbidden in forbiddenText where !forbidden.isEmpty && strings.contains(where: { $0.contains(forbidden) }) {
            violations.append(.forbiddenText(forbidden))
        }
        return violations
    }

    private static func allStrings(in value: Any) -> [String] {
        switch value {
        case let string as String: [string]
        case let array as [Any]: array.flatMap(allStrings(in:))
        case let object as [String: Any]: object.keys.map { $0 } + object.values.flatMap(allStrings(in:))
        default: []
        }
    }

    private static func toolNames(_ tools: [[String: Any]], prefix: String = "") -> [String] {
        tools.flatMap { tool -> [String] in
            let name = tool["name"] as? String ?? tool["type"] as? String ?? "?"
            if tool["type"] as? String == "namespace" {
                return toolNames(tool["tools"] as? [[String: Any]] ?? [], prefix: prefix + name + ".")
            }
            return [prefix + name]
        }
    }

    private static func text(of message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}
