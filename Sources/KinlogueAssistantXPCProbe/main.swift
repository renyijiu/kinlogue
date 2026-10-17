import Foundation
import KinlogueAssistantIPC

// Drives the assistant bridge XPC service from a signed, sandboxed host, through the same client
// the App uses, and prints one `KL_PROBE` line of key=value pairs. It is never packaged.
//
//   KinlogueAssistantXPCProbe status <service> [--executable PATH] [--model MODEL]
//   KinlogueAssistantXPCProbe respond <service> --model MODEL [--executable PATH] [--cancel-after SECONDS]
//   KinlogueAssistantXPCProbe ask <service> --model MODEL [--executable PATH] < request.json
//
// `status` and `respond` serve scripts/verify-assistant-xpc.sh with fixed synthetic text. `ask`
// serves the manual matrix in docs/acceptance/member-chat-matrix.md: it sends the instructions and
// input of a JSON object read from stdin, which must hold synthetic data only, and adds a
// `KL_PROBE_ANSWER` line with the answer as a JSON string.

let arguments = CommandLine.arguments
guard arguments.count >= 3, ["status", "respond", "ask"].contains(arguments[1]) else {
    print("KL_PROBE kind=usage")
    exit(64)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func run() async -> String {
    let client = KinlogueAssistantXPCClient(serviceName: arguments[2])
    guard let configuration = try? KinlogueAssistantCLIConfiguration(executablePath: option("--executable"), proxy: [:]) else {
        return "KL_PROBE kind=invalidRequest"
    }
    if arguments[1] == "status" {
        guard let request = try? KinlogueAssistantStatusRequest(configuration: configuration, model: option("--model")),
              let encoded = try? KinlogueAssistantIPCCodec.encode(request) else { return "KL_PROBE kind=invalidRequest" }
        guard let data = await client.status(encoded) else { return "KL_PROBE kind=xpcError" }
        guard let status = try? KinlogueAssistantIPCCodec.decodeStatus(data) else { return "KL_PROBE kind=undecodable" }
        return "KL_PROBE kind=status failure=\(status.failure?.rawValue ?? "none") version=\(status.cliVersion ?? "none")"
            + " loggedIn=\(status.isLoggedIn) verified=\(status.isVerifiedVersion) model=\(status.model ?? "none")"
            + " models=\(status.models.count) default=\(status.defaultModel ?? "none")"
    }
    var instructions = "Synthetic verification instructions."
    var input = "<question>\nSynthetic verification\n</question>\n"
    if arguments[1] == "ask" {
        struct Ask: Decodable { let instructions: String; let input: String }
        guard let ask = try? JSONDecoder().decode(Ask.self, from: FileHandle.standardInput.readDataToEndOfFile()) else {
            return "KL_PROBE kind=invalidRequest"
        }
        instructions = ask.instructions
        input = ask.input
    }
    let requestID = UUID()
    guard let request = try? KinlogueAssistantTurnRequest(
        requestID: requestID, configuration: configuration, model: option("--model") ?? "gpt-synthetic",
        instructions: instructions, input: input
    ), let encoded = try? KinlogueAssistantIPCCodec.encode(request) else { return "KL_PROBE kind=invalidRequest" }
    // As the App's stop button would: cancel the task, which sends the cancel on the same connection.
    let turn = Task { await client.respond(encoded, requestID: requestID) }
    if let seconds = option("--cancel-after").flatMap(Double.init) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            turn.cancel()
        }
    }
    guard let data = await turn.value else { return "KL_PROBE kind=xpcError" }
    switch try? KinlogueAssistantIPCCodec.decodeTurnResponse(data) {
    case let .answer(text, cliVersion, model)? where arguments[1] == "ask":
        let answer = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return "KL_PROBE_ANSWER \(answer)\nKL_PROBE kind=answer version=\(cliVersion) model=\(model)"
    case let .answer(text, cliVersion, _)?:
        return "KL_PROBE kind=answer version=\(cliVersion) text=\(text.replacingOccurrences(of: " ", with: "_"))"
    case let .failure(code, exitCode)?:
        return "KL_PROBE kind=failure code=\(code.rawValue) exit=\(exitCode.map(String.init) ?? "none")"
    case nil:
        return "KL_PROBE kind=undecodable"
    }
}

print(await run())
