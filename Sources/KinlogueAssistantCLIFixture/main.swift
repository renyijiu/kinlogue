import Darwin
import Foundation
import KinlogueAssistantCLI
import os

// A fake `codex` for the bridge tests. It reads its scenario from `$HOME/kl-fake-codex.json` and
// answers the subcommands the bridge uses with the output shapes recorded in the U0 probe. It also
// serves as the supervisor and as a throwaway host process for the parent-death test. It is never
// packaged.

let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == CLISupervisor.flag {
    CLISupervisor.run(arguments: arguments)
}

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
let scenario = (try? JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: home + "/kl-fake-codex.json"))
)) as? [String: Any] ?? [:]

@MainActor
func emit(_ object: [String: Any]) {
    var line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

@MainActor
func writeFile(_ name: String, _ text: String) {
    try? text.write(toFile: home + "/" + name, atomically: true, encoding: .utf8)
}

@MainActor
func sleepForever() -> Never {
    while true { sleep(1_000) }
}

@MainActor
func spawnSelf(_ extra: [String]) {
    let argv = ([arguments[0]] + extra).map { strdup($0) } + [nil]
    let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    _ = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
        posix_spawn(&pid, arguments[0], nil, nil, a.baseAddress!, e.baseAddress!)
    } }
}

@MainActor
func configValue(_ key: String) -> String? {
    let configs = arguments.indices.filter { arguments[$0] == "--config" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    guard let raw = configs.first(where: { $0.hasPrefix(key + "=") })?.dropFirst(key.count + 1) else { return nil }
    // Values are TOML basic strings written with JSON escapes.
    return (try? JSONSerialization.jsonObject(with: Data("[\(raw)]".utf8)) as? [String])?.first
}

@MainActor
func option(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

@MainActor
func record(_ name: String, stdinBytes: Int) {
    let object: [String: Any] = [
        "arguments": Array(arguments.dropFirst()),
        // Foundation adds __CF_USER_TEXT_ENCODING to every Foundation process at launch, this fake
        // included; the real CLI is not a Foundation program.
        "environmentKeys": ProcessInfo.processInfo.environment.keys.filter { $0 != "__CF_USER_TEXT_ENCODING" }.sorted(),
        "workingDirectory": FileManager.default.currentDirectoryPath,
        "stdinBytes": stdinBytes,
        "processGroupLeader": getpgrp() == getpid(),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: object) {
        try? data.write(to: URL(fileURLWithPath: home + "/" + name))
    }
}

@MainActor
func runCheck(input: Data) -> Never {
    record("kl-fake-record-check.json", stdinBytes: input.count)
    guard let baseURL = configValue("model_providers.kinlogue_check.base_url"),
          let keyName = configValue("model_providers.kinlogue_check.env_key"),
          let url = URL(string: baseURL + "/responses") else { exit(2) }
    let instructions = configValue("instructions") ?? ""
    var userText = String(decoding: input, as: UTF8.self)
    func message(_ role: String, _ text: String) -> [String: Any] {
        ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
    }
    var items = [message("developer", instructions)]
    var body: [String: Any] = ["model": option("--model") ?? "", "store": false, "stream": true]
    switch scenario["check"] as? String ?? "clean" {
    case "tools":
        items.insert(["type": "additional_tools", "role": "developer", "tools": [
            ["type": "namespace", "name": "functions", "tools": [["type": "custom", "name": "exec"]]],
        ]], at: 0)
    case "leakHome":
        userText += "\n" + home
    case "extraMessage":
        items.append(message("developer", "<environment_context>synthetic</environment_context>"))
    default:
        break
    }
    items.append(message("user", userText))
    body["input"] = items

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer " + (ProcessInfo.processInfo.environment[keyName] ?? ""), forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let finished = DispatchSemaphore(value: 0)
    let answer = OSAllocatedUnfairLock<String?>(initialState: nil)
    URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, _ in
        for line in String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  event["type"] as? String == "response.completed",
                  let output = (event["response"] as? [String: Any])?["output"] as? [[String: Any]],
                  let content = output.first?["content"] as? [[String: Any]] else { continue }
            let text = content.first?["text"] as? String
            answer.withLock { $0 = text }
        }
        finished.signal()
    }.resume()
    finished.wait()
    emit(["type": "thread.started", "thread_id": "fake-check"])
    emit(["type": "turn.started"])
    emit(["type": "item.completed", "item": ["id": "item_0", "type": "agent_message", "text": answer.withLock { $0 } ?? ""]])
    emit(["type": "turn.completed", "usage": ["input_tokens": 1, "output_tokens": 1]])
    exit(0)
}

@MainActor
func runTurn(input: Data) -> Never {
    record("kl-fake-record-turn.json", stdinBytes: input.count)
    switch scenario["turn"] as? String ?? "answer" {
    case "answer":
        emit(["type": "thread.started", "thread_id": "fake-turn"])
        emit(["type": "turn.started"])
        emit(["type": "item.completed", "item": ["id": "item_0", "type": "reasoning", "text": "…"]])
        emit(["type": "item.completed", "item": ["id": "item_1", "type": "agent_message", "text": "fake answer bytes=\(input.count)"]])
        emit(["type": "turn.completed", "usage": ["input_tokens": 1, "output_tokens": 1]])
        exit(0)
    case "silent":
        writeFile("codex.pid", String(getpid()))
        sleepForever()
    case "hang":
        writeFile("codex.pid", String(getpid()))
        emit(["type": "thread.started", "thread_id": "fake-hang"])
        spawnSelf(["--sleep-forever"])
        sleepForever()
    case "flood":
        writeFile("codex.pid", String(getpid()))
        let line = Data((String(repeating: "x", count: 1_023) + "\n").utf8)
        while true { FileHandle.standardOutput.write(line) }
    case "longLine":
        writeFile("codex.pid", String(getpid()))
        FileHandle.standardOutput.write(Data(String(repeating: "y", count: 300 * 1_024).utf8))
        sleepForever()
    case "toolUse":
        writeFile("codex.pid", String(getpid()))
        emit(["type": "thread.started", "thread_id": "fake-tool"])
        emit(["type": "item.started", "item": ["id": "item_0", "type": "command_execution", "command": "ls"]])
        sleepForever()
    case "failed401":
        emit(["type": "thread.started", "thread_id": "fake-401"])
        emit(["type": "turn.failed", "error": ["message": "unexpected status 401 Unauthorized"]])
        exit(1)
    case "rateLimited":
        emit(["type": "thread.started", "thread_id": "fake-429"])
        emit(["type": "turn.failed", "error": ["message": "exceeded retry limit, last status: 429 Too Many Requests"]])
        exit(1)
    case "exit3":
        exit(3)
    case "noCompletion":
        emit(["type": "thread.started", "thread_id": "fake-partial"])
        emit(["type": "item.completed", "item": ["id": "item_0", "type": "agent_message", "text": "partial"]])
        exit(0)
    default:
        exit(64)
    }
}

switch arguments.dropFirst().first {
case "--version":
    print("codex-cli " + (scenario["version"] as? String ?? "0.162.0"))
case "--sleep-forever":
    writeFile("grandchild.pid", String(getpid()))
    sleepForever()
case "--host-hanging-turn":
    let executable = URL(fileURLWithPath: arguments[0])
    var limits = CLIProcessLimits()
    limits.totalTimeout = 600
    _ = CLIProcess.run(
        executable: executable, arguments: ["exec", "--json", "-"], environment: ["HOME": home],
        workingDirectory: home, input: Data("x".utf8), supervisor: executable, limits: limits,
        cancellation: nil, onLine: { _ in }
    )
case "login":
    if scenario["loggedOut"] as? Bool == true {
        FileHandle.standardError.write(Data("Not logged in\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("Logged in using ChatGPT\n".utf8))
case "features":
    if scenario["features"] as? String == "malformed" {
        print("Usage: codex features <COMMAND>")
        exit(0)
    }
    let disabled = Set(arguments.indices.filter { arguments[$0] == "--disable" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] })
    let sticky = scenario["stickyFeature"] as? Bool == true
    for (name, stage, enabled) in [
        ("apps", "stable", true), ("auth_elicitation", "stable", true), ("code_mode", "under development", false),
        ("collaboration_modes", "removed", true), ("shell_tool", "stable", true),
    ] {
        let on = enabled && (!disabled.contains(name) || (sticky && name == "shell_tool"))
        print(name.padding(toLength: 36, withPad: " ", startingAt: 0) + stage.padding(toLength: 19, withPad: " ", startingAt: 0) + String(on))
    }
case "debug":
    print(#"{"models":[{"slug":"gpt-synthetic","tool_mode":"code_mode_only","apply_patch_tool_type":"freeform","experimental_supported_tools":["clock"]}]}"#)
case "exec":
    if arguments.contains("--help") {
        let flags = CodexInvocation.requiredExecFlags.filter {
            !(scenario["missingFlag"] as? Bool == true && $0 == "--strict-config")
        }
        print((flags + ["--color"]).map { "      \($0) <VALUE>" }.joined(separator: "\n"))
        exit(0)
    }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if configValue("model_provider") == "kinlogue_check" {
        runCheck(input: input)
    }
    runTurn(input: input)
default:
    exit(64)
}
