import Foundation
import KinlogueAssistantIPC
import Testing

struct AssistantIPCTests {
    @Test
    func turnRequestsResponsesAndStatusRoundTripThroughTheBoundedCodec() throws {
        let request = try KinlogueAssistantTurnRequest(
            requestID: UUID(),
            configuration: KinlogueAssistantCLIConfiguration(
                executablePath: "/opt/homebrew/bin/codex",
                proxy: ["HTTPS_PROXY": "http://127.0.0.1:6152"]
            ),
            model: "gpt-synthetic-1.0",
            instructions: "Synthetic instructions",
            input: "<records>\n合成\n</records>"
        )
        let decodedRequest = try KinlogueAssistantIPCCodec.decodeTurnRequest(
            KinlogueAssistantIPCCodec.encode(request)
        )
        #expect(decodedRequest == request)

        for response in [
            KinlogueAssistantTurnResponse.answer(text: "答案 [R1]", cliVersion: "0.162.0", model: "gpt-synthetic-1.0"),
            .failure(code: .notLoggedIn, exitCode: 1),
            .failure(code: .cancelled, exitCode: nil),
        ] {
            #expect(try KinlogueAssistantIPCCodec.decodeTurnResponse(KinlogueAssistantIPCCodec.encode(response)) == response)
        }

        let status = KinlogueAssistantStatus(
            executablePath: "/opt/homebrew/Caskroom/codex/0.162.0/bin/codex",
            cliVersion: "0.162.0", isLoggedIn: true, isVerifiedVersion: true, failure: nil,
            model: "gpt-synthetic-mini", defaultModel: "gpt-synthetic",
            models: [.init(slug: "gpt-synthetic-mini", displayName: "GPT Synthetic Mini"), .init(slug: "gpt-synthetic", displayName: "合成模型")]
        )
        #expect(try KinlogueAssistantIPCCodec.decodeStatus(KinlogueAssistantIPCCodec.encode(status)) == status)
        let statusRequest = try KinlogueAssistantStatusRequest(configuration: .init(executablePath: nil, proxy: [:]))
        #expect(try KinlogueAssistantIPCCodec.decodeStatusRequest(KinlogueAssistantIPCCodec.encode(statusRequest)) == statusRequest)
    }

    @Test
    func requestsRejectUnboundedOrInjectableFields() throws {
        func turn(
            path: String? = nil,
            proxy: [String: String] = [:],
            model: String = "gpt-synthetic",
            instructions: String = "Instructions",
            input: String = "Input"
        ) throws -> KinlogueAssistantTurnRequest {
            try KinlogueAssistantTurnRequest(
                requestID: UUID(),
                configuration: KinlogueAssistantCLIConfiguration(executablePath: path, proxy: proxy),
                model: model, instructions: instructions, input: input
            )
        }

        _ = try turn()
        for invalid: () throws -> KinlogueAssistantTurnRequest in [
            { try turn(path: "relative/codex") },
            { try turn(path: "/opt/homebrew/bin/codex\u{0}") },
            { try turn(path: "/" + String(repeating: "a", count: KinlogueAssistantIPCLimits.maximumPathBytes)) },
            { try turn(proxy: ["DYLD_INSERT_LIBRARIES": "/tmp/x"]) },
            { try turn(proxy: ["HTTPS_PROXY": "http://127.0.0.1:1\nX=1"]) },
            { try turn(model: "") },
            { try turn(model: "gpt synthetic") },
            { try turn(model: "-c") },
            { try turn(model: String(repeating: "m", count: KinlogueAssistantIPCLimits.maximumFieldBytes + 1)) },
            { try turn(instructions: "") },
            { try turn(instructions: String(repeating: "i", count: KinlogueAssistantIPCLimits.maximumInstructionsBytes + 1)) },
            { try turn(input: " ") },
            { try turn(input: "a\u{0}b") },
            { try turn(input: String(repeating: "x", count: KinlogueAssistantIPCLimits.maximumInputBytes + 1)) },
        ] {
            #expect(throws: KinlogueAssistantIPCValidationError.invalidField) { _ = try invalid() }
        }
    }

    @Test
    func statusRejectsUnsafeModelChoices() throws {
        func status(default defaultModel: String? = nil, _ models: [KinlogueAssistantModelChoice]) -> KinlogueAssistantStatus {
            KinlogueAssistantStatus(
                executablePath: nil, cliVersion: "0.162.0", isLoggedIn: true, isVerifiedVersion: true, failure: nil,
                defaultModel: defaultModel, models: models
            )
        }

        _ = try KinlogueAssistantIPCCodec.encode(status(default: "gpt-a", [.init(slug: "gpt-a", displayName: "GPT A")]))
        for invalid in [
            status(default: "-c", []),
            status([.init(slug: "-c", displayName: "Injected")]),
            status([.init(slug: "gpt-a", displayName: " ")]),
            status([.init(slug: "gpt-a", displayName: "a\nb")]),
            status([.init(slug: "gpt-a", displayName: String(repeating: "x", count: KinlogueAssistantIPCLimits.maximumModelNameBytes + 1))]),
            status([.init(slug: "gpt-a", displayName: "A"), .init(slug: "gpt-a", displayName: "B")]),
            status((0...KinlogueAssistantIPCLimits.maximumModelChoices).map { .init(slug: "gpt-\($0)", displayName: "M\($0)") }),
        ] {
            #expect(throws: KinlogueAssistantIPCValidationError.invalidField) { _ = try KinlogueAssistantIPCCodec.encode(invalid) }
        }
    }

    @Test
    func decodingRejectsOversizedFramesForeignVersionsAndInvalidAnswers() throws {
        let oversized = Data(repeating: 0x20, count: KinlogueAssistantIPCLimits.maximumRequestBytes + 1)
        #expect(throws: KinlogueAssistantIPCValidationError.frameTooLarge) {
            try KinlogueAssistantIPCCodec.decodeTurnRequest(oversized)
        }
        #expect(throws: KinlogueAssistantIPCValidationError.invalidEncoding) {
            try KinlogueAssistantIPCCodec.decodeTurnRequest(Data("not a plist".utf8))
        }

        let request = try KinlogueAssistantStatusRequest(configuration: .init(executablePath: nil, proxy: [:]))
        var object = try #require(PropertyListSerialization.propertyList(
            from: KinlogueAssistantIPCCodec.encode(request), format: nil
        ) as? [String: Any])
        object["version"] = Int(KinlogueAssistantIPCLimits.protocolVersion) + 1
        let foreign = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        #expect(throws: KinlogueAssistantIPCValidationError.unsupportedVersion) {
            try KinlogueAssistantIPCCodec.decodeStatusRequest(foreign)
        }

        let tooLong = KinlogueAssistantTurnResponse.answer(
            text: String(repeating: "a", count: KinlogueAssistantIPCLimits.maximumAnswerBytes + 1),
            cliVersion: "0.162.0", model: "gpt-synthetic"
        )
        #expect(throws: KinlogueAssistantIPCValidationError.invalidField) { try KinlogueAssistantIPCCodec.encode(tooLong) }
        #expect(throws: KinlogueAssistantIPCValidationError.invalidField) {
            try KinlogueAssistantIPCCodec.encode(KinlogueAssistantTurnResponse.answer(text: " ", cliVersion: "0.162.0", model: "m"))
        }
    }
}
