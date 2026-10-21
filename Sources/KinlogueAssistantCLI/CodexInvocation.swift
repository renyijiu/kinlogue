import Foundation
import KinlogueAssistantIPC

public enum CodexAdapterError: Error, Equatable, Sendable {
    case malformedFeatureList
    case malformedModelCatalog
    case malformedOutput
    case toolUseDetected
}

/// The fixed command line for one Codex turn, as measured in the U0 probe on 0.162.0
/// (docs/sources/2026-10-15-codex-u0-probe-evidence.md). The turn's input never appears here; it
/// goes to stdin.
public enum CodexInvocation {
    /// Versions whose hardening was verified with real requests. Other versions still run when
    /// every capability check passes, and are shown as unverified.
    public static let verifiedVersions: Set<String> = ["0.162.0"]

    /// Enabled features that may stay on. Every other enabled feature is disabled by name.
    public static let allowedFeatures: Set<String> = [
        "auth_elicitation", "compaction_image_budget", "content_item_kinds", "fast_mode",
        "ultrafast_mode", "system_proxy_fallback", "api_key_model_discovery",
    ]

    public static let configOverrides = [
        #"web_search="disabled""#,
        "include_environment_context=false",
        "include_permissions_instructions=false",
        "include_collaboration_mode_instructions=false",
        "include_apps_instructions=false",
        "project_doc_max_bytes=0",
        "check_for_update_on_startup=false",
        "skills.include_instructions=false",
        #"history.persistence="none""#,
        "analytics.enabled=false",
        "feedback.enabled=false",
        #"otel.exporter="none""#,
        #"otel.trace_exporter="none""#,
        #"otel.metrics_exporter="none""#,
        "otel.log_user_prompt=false",
        "tools.experimental_request_user_input.enabled=false",
        "agents.enabled=false",
    ]

    /// Options `exec --help` must list before the CLI is used.
    public static let requiredExecFlags = [
        "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config",
        "--skip-git-repo-check", "--sandbox", "--cd", "--model", "--config", "--disable",
    ]

    /// A loopback Responses endpoint that stands in for the provider during the capability check.
    public struct MockProvider: Equatable, Sendable {
        public let baseURL: String
        public let environmentKey: String

        public init(baseURL: String, environmentKey: String) {
            self.baseURL = baseURL
            self.environmentKey = environmentKey
        }
    }

    public static func execArguments(
        workingDirectory: String,
        model: String,
        catalogPath: String,
        instructions: String,
        disabledFeatures: [String],
        mockProvider: MockProvider?
    ) -> [String] {
        var arguments = [
            "exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config",
            "--skip-git-repo-check", "--sandbox", "read-only", "--cd", workingDirectory, "--model", model,
            "--color", "never",
        ]
        for feature in disabledFeatures {
            arguments += ["--disable", feature]
        }
        var overrides = configOverrides
        overrides.append("model_catalog_json=" + tomlString(catalogPath))
        overrides.append("instructions=" + tomlString(instructions))
        if let mockProvider {
            let provider = "model_providers.kinlogue_check"
            overrides += [
                #"model_provider="kinlogue_check""#,
                #"\#(provider).name="Kinlogue capability check""#,
                "\(provider).base_url=" + tomlString(mockProvider.baseURL),
                "\(provider).env_key=" + tomlString(mockProvider.environmentKey),
                #"\#(provider).wire_api="responses""#,
                "\(provider).request_max_retries=0",
                "\(provider).stream_max_retries=0",
            ]
        }
        for override in overrides {
            arguments += ["--config", override]
        }
        arguments.append("-")
        return arguments
    }

    /// `codex-cli 0.162.0` → `0.162.0`. Anything else is not a version this adapter knows.
    public static func version(fromVersionOutput output: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "codex-cli "
        guard line.hasPrefix(prefix) else { return nil }
        let version = String(line.dropFirst(prefix.count))
        guard let first = version.unicodeScalars.first, CharacterSet.decimalDigits.contains(first),
              version.utf8.count <= 64,
              version.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-+".unicodeScalars.contains($0)) })
        else { return nil }
        return version
    }

    public static func isVerified(version: String) -> Bool {
        verifiedVersions.contains(version)
    }

    public static func missingExecFlags(inHelp help: String) -> [String] {
        let words = Set(help.split { $0.isWhitespace || $0 == "," || $0 == "=" }.map(String.init))
        return requiredExecFlags.filter { !words.contains($0) }
    }

    /// `codex login status` prints its result to stderr and exits 0 when logged in.
    public static func isLoggedIn(statusOutput: String, exitStatus: Int32) -> Bool {
        exitStatus == 0 && statusOutput.contains("Logged in")
    }

    /// A TOML basic string. JSON's escapes are a subset of TOML's once slashes stay unescaped.
    static func tomlString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

public struct CodexFeature: Equatable, Sendable {
    public let name: String
    public let stage: String
    public let isEnabled: Bool
}

/// Reads `codex features list`: a name, a stage of one or more words, and `true` or `false`.
public enum CodexFeatureList {
    public static func parse(_ output: String) throws -> [CodexFeature] {
        let features = try output.split(whereSeparator: \.isNewline).map { line -> CodexFeature in
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 3, let enabled = Bool(tokens[tokens.count - 1]), isFeatureName(tokens[0]) else {
                throw CodexAdapterError.malformedFeatureList
            }
            return CodexFeature(name: tokens[0], stage: tokens[1..<(tokens.count - 1)].joined(separator: " "), isEnabled: enabled)
        }
        guard !features.isEmpty else { throw CodexAdapterError.malformedFeatureList }
        return features
    }

    /// Enabled features outside the allow-list. Removed features cannot be toggled and are left alone.
    public static func featuresToDisable(_ features: [CodexFeature]) -> [String] {
        features
            .filter { $0.isEnabled && $0.stage != "removed" && !CodexInvocation.allowedFeatures.contains($0.name) }
            .map(\.name)
            .sorted()
    }

    /// Lowercase words joined by `_`, and `.` for nested names such as `guardianv2.thread_context`.
    private static func isFeatureName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, ("a"..."z").contains(first), value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "." }
    }
}

/// Rewrites the output of `codex debug models` so no model brings its own tools: the U0 probe found
/// every model marked `code_mode_only`, which advertises code-mode tools even with all features off.
public enum CodexModelCatalog {
    public static let maximumBytes = 8 * 1_024 * 1_024
    static let removedFields = ["tool_mode", "apply_patch_tool_type", "web_search_tool_type", "multi_agent_version"]

    /// The model slugs in catalog order.
    public static func slugs(_ data: Data) throws -> [String] {
        guard data.count <= maximumBytes,
              let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]], !models.isEmpty else {
            throw CodexAdapterError.malformedModelCatalog
        }
        let slugs = models.compactMap { $0["slug"] as? String }.filter { !$0.isEmpty }
        guard slugs.count == models.count else { throw CodexAdapterError.malformedModelCatalog }
        return slugs
    }

    /// The models Codex shows in its own picker (`visibility` "list", or none given), ordered by
    /// `priority` and then catalog position. A slug that is not a token is left out; a shown name
    /// that is unsafe to display falls back to the slug.
    public static func choices(_ data: Data) throws -> [KinlogueAssistantModelChoice] {
        guard data.count <= maximumBytes,
              let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]], !models.isEmpty else {
            throw CodexAdapterError.malformedModelCatalog
        }
        var seen = Set<String>()
        let shown = models.enumerated().compactMap { position, model -> (rank: Int, position: Int, choice: KinlogueAssistantModelChoice)? in
            guard let slug = model["slug"] as? String, KinlogueAssistantText.isToken(slug),
                  (model["visibility"] as? String ?? "list") == "list", seen.insert(slug).inserted else { return nil }
            let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.flatMap { KinlogueAssistantText.isDisplayName($0) ? $0 : nil } ?? slug
            return ((model["priority"] as? Int) ?? .max, position, KinlogueAssistantModelChoice(slug: slug, displayName: displayName))
        }
        return shown.sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }
            .prefix(KinlogueAssistantIPCLimits.maximumModelChoices).map(\.choice)
    }

    public static func rewrite(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes,
              var catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var models = catalog["models"] as? [[String: Any]], !models.isEmpty,
              models.allSatisfy({ ($0["slug"] as? String).map { !$0.isEmpty } ?? false }) else {
            throw CodexAdapterError.malformedModelCatalog
        }
        for index in models.indices {
            for field in removedFields {
                models[index].removeValue(forKey: field)
            }
            models[index]["experimental_supported_tools"] = [String]()
            models[index]["supports_search_tool"] = false
        }
        catalog["models"] = models
        return try JSONSerialization.data(withJSONObject: catalog)
    }
}
