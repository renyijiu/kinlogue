import Foundation
import KinlogueAssistantCLI
import KinlogueAssistantIPC
import Testing

struct AssistantCodexAdapterTests {
    @Test
    func execArgumentsCarryTheHardeningAndNeverTheInput() throws {
        let arguments = CodexInvocation.execArguments(
            workingDirectory: "/private/var/synthetic/cwd",
            model: "gpt-synthetic",
            catalogPath: "/private/var/synthetic/catalog.json",
            instructions: "Line one\nLine \"two\"",
            disabledFeatures: ["shell_tool", "apps"],
            mockProvider: nil
        )

        #expect(Array(arguments.prefix(2)) == ["exec", "--json"])
        #expect(arguments.last == "-")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config", "--skip-git-repo-check"] {
            #expect(arguments.contains(flag), "missing \(flag)")
        }
        #expect(pair(arguments, "--sandbox") == "read-only")
        #expect(pair(arguments, "--cd") == "/private/var/synthetic/cwd")
        #expect(pair(arguments, "--model") == "gpt-synthetic")
        #expect(values(arguments, "--disable") == ["shell_tool", "apps"])
        let configs = values(arguments, "--config")
        for override in CodexInvocation.configOverrides {
            #expect(configs.contains(override), "missing \(override)")
        }
        #expect(configs.contains(#"model_catalog_json="/private/var/synthetic/catalog.json""#))
        #expect(configs.contains(#"instructions="Line one\nLine \"two\"""#))
        #expect(!configs.contains { $0.hasPrefix("model_provider") })
        #expect(configs.contains("agents.enabled=false"))
        #expect(configs.contains(#"history.persistence="none""#))
    }

    @Test
    func mockProviderArgumentsPointCodexAtTheLoopbackServerOnly() {
        let arguments = CodexInvocation.execArguments(
            workingDirectory: "/w", model: "gpt-synthetic", catalogPath: "/c.json", instructions: "I",
            disabledFeatures: [], mockProvider: .init(baseURL: "http://127.0.0.1:49152/v1", environmentKey: "KL_MOCK_KEY")
        )
        let configs = values(arguments, "--config")

        #expect(configs.contains(#"model_provider="kinlogue_check""#))
        #expect(configs.contains(#"model_providers.kinlogue_check.base_url="http://127.0.0.1:49152/v1""#))
        #expect(configs.contains(#"model_providers.kinlogue_check.env_key="KL_MOCK_KEY""#))
        #expect(configs.contains(#"model_providers.kinlogue_check.wire_api="responses""#))
        #expect(configs.contains("model_providers.kinlogue_check.request_max_retries=0"))
    }

    @Test
    func versionHelpAndLoginOutputsAreReadStrictly() {
        #expect(CodexInvocation.version(fromVersionOutput: "codex-cli 0.162.0\n") == "0.162.0")
        #expect(CodexInvocation.version(fromVersionOutput: "codex-cli 0.163.0-alpha.2") == "0.163.0-alpha.2")
        #expect(CodexInvocation.version(fromVersionOutput: "codex 0.162.0") == nil)
        #expect(CodexInvocation.version(fromVersionOutput: "codex-cli 0.162.0; rm -rf ~") == nil)
        #expect(CodexInvocation.isVerified(version: "0.162.0"))
        #expect(!CodexInvocation.isVerified(version: "0.163.0"))

        let help = CodexInvocation.requiredExecFlags.map { "      \($0) <VALUE>\n          Text" }.joined(separator: "\n")
        #expect(CodexInvocation.missingExecFlags(inHelp: help).isEmpty)
        let partial = help.replacingOccurrences(of: "--strict-config", with: "--lenient-config")
        #expect(CodexInvocation.missingExecFlags(inHelp: partial) == ["--strict-config"])

        #expect(CodexInvocation.isLoggedIn(statusOutput: "Logged in using ChatGPT\n", exitStatus: 0))
        #expect(!CodexInvocation.isLoggedIn(statusOutput: "Not logged in\n", exitStatus: 1))
        #expect(!CodexInvocation.isLoggedIn(statusOutput: "Logged in using ChatGPT\n", exitStatus: 1))
    }

    @Test
    func featureListDisablesEverythingEnabledOutsideTheAllowList() throws {
        let listing = """
        apps                                stable             true
        auth_elicitation                    stable             true
        code_mode                           under development  false
        collaboration_modes                 removed            true
        fast_mode                           stable             true
        guardianv2.thread_context           under development  true
        shell_tool                          stable             true
        skip_host_skill_discovery           under development  false
        brand_new_tool                      experimental       true
        """

        let features = try CodexFeatureList.parse(listing)

        #expect(features.count == 9)
        #expect(features.first(where: { $0.name == "code_mode" })?.stage == "under development")
        #expect(CodexFeatureList.featuresToDisable(features) == ["apps", "brand_new_tool", "guardianv2.thread_context", "shell_tool"])
        for malformed in ["", "apps stable maybe", "apps true", "Usage: codex features", "-c stable true", "Apps stable true"] {
            #expect(throws: CodexAdapterError.malformedFeatureList) { try CodexFeatureList.parse(malformed) }
        }
    }

    @Test
    func modelCatalogRewriteRemovesEveryToolBearingField() throws {
        let catalog: [String: Any] = ["models": [
            ["slug": "gpt-synthetic", "tool_mode": "code_mode_only", "apply_patch_tool_type": "freeform",
             "web_search_tool_type": "text_and_image", "multi_agent_version": "v2",
             "experimental_supported_tools": ["clock"], "supports_search_tool": true, "context_window": 400_000],
            ["slug": "gpt-other", "tool_mode": "code_mode_only"],
        ]]

        let rewritten = try CodexModelCatalog.rewrite(JSONSerialization.data(withJSONObject: catalog))
        let models = try #require(
            (try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])?["models"] as? [[String: Any]]
        )

        #expect(models.count == 2)
        for model in models {
            for removed in ["tool_mode", "apply_patch_tool_type", "web_search_tool_type", "multi_agent_version"] {
                #expect(model[removed] == nil)
            }
            #expect((model["experimental_supported_tools"] as? [Any])?.isEmpty == true)
            #expect(model["supports_search_tool"] as? Bool == false)
        }
        #expect(models[0]["context_window"] as? Int == 400_000)

        for invalid in [Data("[]".utf8), Data(#"{"models":[]}"#.utf8), Data(#"{"models":[{"id":1}]}"#.utf8), Data("x".utf8)] {
            #expect(throws: CodexAdapterError.malformedModelCatalog) { try CodexModelCatalog.rewrite(invalid) }
        }
        #expect(throws: CodexAdapterError.malformedModelCatalog) {
            try CodexModelCatalog.rewrite(Data(count: CodexModelCatalog.maximumBytes + 1))
        }
    }

    @Test
    func eventStreamYieldsTheLastAgentMessageOnlyAfterTheTurnCompletes() throws {
        var events = CodexEventAccumulator()
        for line in [
            #"{"type":"thread.started","thread_id":"01a13db6-0000-7000-8000-000000000000"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Under-development features enabled"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"reasoning","text":"…"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Preamble"}}"#,
            #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"- 2021-02-11：5.1 mmol/L [R1]"}}"#,
        ] {
            try events.consume(Data(line.utf8))
        }
        #expect(events.threadStarted)
        #expect(events.answer == nil)

        try events.consume(Data(#"{"type":"turn.completed","usage":{"input_tokens":705,"output_tokens":79}}"#.utf8))

        #expect(events.answer == "- 2021-02-11：5.1 mmol/L [R1]")
        #expect(events.failureMessage == nil)
    }

    @Test
    func eventStreamStopsOnToolUseAndRecordsTurnFailures() throws {
        for tool in ["command_execution", "file_change", "mcp_tool_call", "web_search", "todo_list", "something_new"] {
            var events = CodexEventAccumulator()
            #expect(throws: CodexAdapterError.toolUseDetected) {
                try events.consume(Data(#"{"type":"item.started","item":{"id":"i","type":"\#(tool)"}}"#.utf8))
            }
        }

        var failed = CodexEventAccumulator()
        try failed.consume(Data(#"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized"}}"#.utf8))
        #expect(failed.failureMessage == "unexpected status 401 Unauthorized")
        #expect(failed.answer == nil)

        var streamError = CodexEventAccumulator()
        try streamError.consume(Data(#"{"type":"error","message":"stream disconnected before completion"}"#.utf8))
        #expect(streamError.failureMessage == "stream disconnected before completion")

        var malformed = CodexEventAccumulator()
        #expect(throws: CodexAdapterError.malformedOutput) { try malformed.consume(Data("not json".utf8)) }
        #expect(throws: CodexAdapterError.malformedOutput) { try malformed.consume(Data("[1]".utf8)) }
        var unknownTop = CodexEventAccumulator()
        try unknownTop.consume(Data(#"{"type":"session.configured"}"#.utf8))
        #expect(unknownTop.answer == nil)
    }

    @Test
    func failureMessagesMapToSemanticCodesWithoutKeepingTheText() {
        #expect(CodexFailureClassifier.code(for: "unexpected status 401 Unauthorized", exitStatus: 1) == .notLoggedIn)
        #expect(CodexFailureClassifier.code(for: "Not logged in. Run codex login", exitStatus: 1) == .notLoggedIn)
        #expect(CodexFailureClassifier.code(for: "exceeded retry limit, last status: 429 Too Many Requests", exitStatus: 1)
            == .rateLimited)
        #expect(CodexFailureClassifier.code(for: "You've hit your usage limit", exitStatus: 1) == .rateLimited)
        #expect(CodexFailureClassifier.code(for: "stream disconnected before completion", exitStatus: 1) == .networkUnavailable)
        #expect(CodexFailureClassifier.code(for: "error sending request for url", exitStatus: 1) == .networkUnavailable)
        #expect(CodexFailureClassifier.code(for: "something else", exitStatus: 3) == .failed)
        #expect(CodexFailureClassifier.code(for: nil, exitStatus: 2) == .failed)
    }

    @Test
    func requestInspectionAcceptsOnlyTheTwoExpectedMessagesAndNoTools() throws {
        let clean = checkRequest()
        #expect(CodexRequestInspection.violations(
            in: clean, instructions: "Synthetic instructions", input: "Synthetic input", forbiddenText: ["/Users/synthetic"]
        ).isEmpty)

        func violations(_ body: Data) -> [CodexRequestViolation] {
            CodexRequestInspection.violations(
                in: body, instructions: "Synthetic instructions", input: "Synthetic input", forbiddenText: ["/Users/synthetic"]
            )
        }
        #expect(violations(checkRequest(tools: [["type": "function", "name": "exec_command"]]))
            == [.toolsAdvertised(["exec_command"])])
        #expect(violations(checkRequest(extraInput: [["type": "additional_tools", "role": "developer", "tools": [
            ["type": "namespace", "name": "functions", "tools": [["type": "custom", "name": "exec"]]],
        ]]])) == [.toolsAdvertised(["functions.exec"])])
        #expect(violations(checkRequest(store: true)) == [.storeEnabled])
        #expect(violations(checkRequest(developer: "You are Codex, an agent")) == [.unexpectedInput])
        #expect(violations(checkRequest(extraInput: [message(role: "developer", text: "<environment_context>")]))
            == [.unexpectedInput])
        #expect(violations(checkRequest(user: "Synthetic input /Users/synthetic/.codex"))
            .contains(.forbiddenText("/Users/synthetic")))
        #expect(violations(Data("{}".utf8)).contains(.unexpectedInput))
        #expect(CodexRequestInspection.violations(
            in: clean, instructions: "Synthetic instructions", input: "Synthetic input", forbiddenText: [], model: "gpt-other"
        ) == [.unexpectedModel])
        #expect(CodexRequestInspection.violations(
            in: clean, instructions: "Synthetic instructions", input: "Synthetic input", forbiddenText: [], model: "gpt-synthetic"
        ).isEmpty)
        #expect(violations(Data("nope".utf8)) == [.notJSON])
    }
}

private func pair(_ arguments: [String], _ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func values(_ arguments: [String], _ flag: String) -> [String] {
    arguments.indices.filter { arguments[$0] == flag && arguments.indices.contains($0 + 1) }.map { arguments[$0 + 1] }
}

private func message(role: String, text: String) -> [String: Any] {
    ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
}

private func checkRequest(
    developer: String = "Synthetic instructions",
    user: String = "Synthetic input",
    tools: [[String: Any]]? = nil,
    extraInput: [[String: Any]] = [],
    store: Bool = false
) -> Data {
    var body: [String: Any] = [
        "model": "gpt-synthetic", "store": store, "stream": true,
        "input": [message(role: "developer", text: developer), message(role: "user", text: user)] + extraInput,
    ]
    if let tools { body["tools"] = tools }
    return try! JSONSerialization.data(withJSONObject: body)
}
