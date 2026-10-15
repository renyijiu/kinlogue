import Foundation
import KinlogueAssistantCLI
import KinlogueAssistantIPC

// The assistant bridge XPC service. The same executable is the supervisor that leads each CLI's
// process group (`--supervise`), so a killed bridge never leaves the CLI running.

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == CLISupervisor.flag {
    CLISupervisor.run(arguments: CommandLine.arguments)
}

/// One instance serves every connection; the bridge itself allows one turn at a time.
private final class AssistantBridgeService: NSObject, KinlogueAssistantBridgeXPCProtocol, Sendable {
    private let bridge: CodexBridge?
    private let queue = DispatchQueue(label: "kinlogue.assistant.bridge", attributes: .concurrent)

    override init() {
        bridge = try? CodexBridge(environment: .current(supervisor: Bundle.main.executablePath))
        super.init()
    }

    func status(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async { [bridge] in
            let status: KinlogueAssistantStatus
            if let request = try? KinlogueAssistantIPCCodec.decodeStatusRequest(request), let bridge {
                status = bridge.status(configuration: request.configuration, model: request.model)
            } else {
                status = KinlogueAssistantStatus(
                    executablePath: nil, cliVersion: nil, isLoggedIn: false, isVerifiedVersion: false,
                    failure: bridge == nil ? .failed : .invalidRequest
                )
            }
            reply((try? KinlogueAssistantIPCCodec.encode(status)) ?? Data())
        }
    }

    func respond(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async { [bridge] in
            let response: KinlogueAssistantTurnResponse
            if let request = try? KinlogueAssistantIPCCodec.decodeTurnRequest(request), let bridge {
                response = bridge.respond(request, cancellation: CLICancellation())
            } else {
                response = .failure(code: bridge == nil ? .failed : .invalidRequest, exitCode: nil)
            }
            reply((try? KinlogueAssistantIPCCodec.encode(response)) ?? Data())
        }
    }

    func cancel(_ requestID: String, reply: @escaping @Sendable (Bool) -> Void) {
        reply(UUID(uuidString: requestID).map { bridge?.cancel(requestID: $0) ?? false } ?? false)
    }

    func connectionInvalidated() {
        bridge?.cancelRunningTurn()
    }
}

private final class AssistantBridgeListener: NSObject, NSXPCListenerDelegate {
    private let service = AssistantBridgeService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = KinlogueAssistantXPCInterface.make()
        connection.exportedObject = service
        connection.invalidationHandler = { [service] in service.connectionInvalidated() }
        connection.resume()
        return true
    }
}

private let delegate = AssistantBridgeListener()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
