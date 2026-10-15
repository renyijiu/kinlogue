import Foundation
import KinlogueAssistantIPC
import os

// Drives the assistant bridge XPC service from a signed, sandboxed host for
// scripts/verify-assistant-xpc.sh. It sends only synthetic text and prints one `KL_PROBE` line of
// key=value pairs. It is never packaged.
//
//   KinlogueAssistantXPCProbe status <service> [--executable PATH] [--model MODEL]
//   KinlogueAssistantXPCProbe respond <service> --model MODEL [--executable PATH] [--cancel-after SECONDS]

let arguments = CommandLine.arguments
guard arguments.count >= 3, ["status", "respond"].contains(arguments[1]) else {
    print("KL_PROBE kind=usage")
    exit(64)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let connection = NSXPCConnection(serviceName: arguments[2])
connection.remoteObjectInterface = KinlogueAssistantXPCInterface.make()
connection.resume()
let finished = DispatchSemaphore(value: 0)
let output = OSAllocatedUnfairLock(initialState: "KL_PROBE kind=noReply")
let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
    output.withLock { $0 = "KL_PROBE kind=xpcError" }
    finished.signal()
} as! KinlogueAssistantBridgeXPCProtocol

do {
    let configuration = try KinlogueAssistantCLIConfiguration(executablePath: option("--executable"), proxy: [:])
    if arguments[1] == "status" {
        let request = try KinlogueAssistantStatusRequest(configuration: configuration, model: option("--model"))
        proxy.status(try KinlogueAssistantIPCCodec.encode(request)) { data in
            if let status = try? KinlogueAssistantIPCCodec.decodeStatus(data) {
                let line = "KL_PROBE kind=status failure=\(status.failure?.rawValue ?? "none") version=\(status.cliVersion ?? "none")"
                    + " loggedIn=\(status.isLoggedIn) verified=\(status.isVerifiedVersion)"
                output.withLock { $0 = line }
            } else {
                output.withLock { $0 = "KL_PROBE kind=undecodable" }
            }
            finished.signal()
        }
    } else {
        let requestID = UUID()
        let request = try KinlogueAssistantTurnRequest(
            requestID: requestID, configuration: configuration, model: option("--model") ?? "gpt-synthetic",
            instructions: "Synthetic verification instructions.", input: "<question>\nSynthetic verification\n</question>\n"
        )
        if let seconds = option("--cancel-after").flatMap(Double.init) {
            // A second connection, as the App's cancel button would send it while the turn runs.
            let service = arguments[2]
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                let canceller = NSXPCConnection(serviceName: service)
                canceller.remoteObjectInterface = KinlogueAssistantXPCInterface.make()
                canceller.resume()
                (canceller.remoteObjectProxy as? KinlogueAssistantBridgeXPCProtocol)?.cancel(requestID.uuidString) { _ in }
            }
        }
        proxy.respond(try KinlogueAssistantIPCCodec.encode(request)) { data in
            let line: String
            switch try? KinlogueAssistantIPCCodec.decodeTurnResponse(data) {
            case let .answer(text, cliVersion, _)?:
                line = "KL_PROBE kind=answer version=\(cliVersion) text=\(text.replacingOccurrences(of: " ", with: "_"))"
            case let .failure(code, exitCode)?:
                line = "KL_PROBE kind=failure code=\(code.rawValue) exit=\(exitCode.map(String.init) ?? "none")"
            case nil:
                line = "KL_PROBE kind=undecodable"
            }
            output.withLock { $0 = line }
            finished.signal()
        }
    }
} catch {
    print("KL_PROBE kind=invalidRequest")
    exit(65)
}

_ = finished.wait(timeout: .now() + 300)
print(output.withLock { $0 })
connection.invalidate()
