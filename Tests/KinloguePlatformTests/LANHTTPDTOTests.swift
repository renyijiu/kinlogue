import Foundation
import Testing
@testable import KinloguePlatform

struct LANHTTPDTOTests {
    private let fileID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!

    @Test
    func reserveRequestRoundTripsWithCanonicalWireID() throws {
        let request = try LANReserveFileRequest(
            remoteFileID: fileID,
            displayName: " page.jpg ",
            declaredByteCount: 12,
            mediaType: " image/jpeg ",
            attemptRevision: 3
        )
        let encoded = try LANHTTPJSONCodec.encode(request)
        let decoded = try LANHTTPJSONCodec.decode(
            LANReserveFileRequest.self,
            from: encoded
        )

        #expect(decoded == request)
        #expect(decoded.mediaType == "image/jpeg")
        #expect(String(decoding: encoded, as: UTF8.self)
            .contains(fileID.uuidString.lowercased()))
        #expect(!String(decoding: encoded, as: UTF8.self)
            .contains(fileID.uuidString.uppercased()))
    }

    @Test
    func strictDecoderRejectsDuplicateUnknownAndNoncanonicalFields() throws {
        let canonical = fileID.uuidString.lowercased()
        let base = "{\"attemptRevision\":0,\"declaredByteCount\":3,"
            + "\"displayName\":\"page.jpg\",\"remoteFileID\":\""
            + canonical
            + "\"}"

        #expect(throws: LANHTTPJSONError.self) {
            try LANHTTPJSONCodec.decode(
                LANReserveFileRequest.self,
                from: Data((
                    String(base.dropLast()) + ",\"displayName\":\"again\"}"
                ).utf8)
            )
        }
        #expect(throws: LANHTTPJSONError.self) {
            try LANHTTPJSONCodec.decode(
                LANReserveFileRequest.self,
                from: Data((
                    String(base.dropLast()) + ",\"extra\":true}"
                ).utf8)
            )
        }
        #expect(throws: LANHTTPJSONError.self) {
            try LANHTTPJSONCodec.decode(
                LANReserveFileRequest.self,
                from: Data(base.replacingOccurrences(
                    of: canonical,
                    with: fileID.uuidString.uppercased()
                ).utf8)
            )
        }
    }

    @Test
    func requestBodyLimitAndNumericBoundsFailClosed() throws {
        let exact = Data(
            repeating: 0x20,
            count: LANHTTPJSONCodec.maximumRequestByteCount
        )
        #expect(throws: LANHTTPJSONError.self) {
            try LANHTTPJSONCodec.decode(LANReserveFileRequest.self, from: exact)
        }
        let oversized = Data(
            repeating: 0x20,
            count: LANHTTPJSONCodec.maximumRequestByteCount + 1
        )
        #expect(throws: LANHTTPJSONError.bodyTooLarge) {
            try LANHTTPJSONCodec.decode(LANReserveFileRequest.self, from: oversized)
        }
        let negative = "{\"attemptRevision\":0,\"declaredByteCount\":-1,"
            + "\"displayName\":\"page.jpg\","
            + "\"remoteFileID\":\"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\"}"
        #expect(throws: LANHTTPJSONError.self) {
            try LANHTTPJSONCodec.decode(
                LANReserveFileRequest.self,
                from: Data(negative.utf8)
            )
        }
    }

    @Test
    func fileStatusAndSessionAreBoundedAndExposeNoInternalIdentity() throws {
        let status = try LANPhoneFileStatus(
            remoteFileID: fileID,
            displayName: "page.jpg",
            declaredByteCount: 3,
            receivedByteCount: 3,
            attemptRevision: 0,
            state: .saved
        )
        let session = try LANFileSessionResponse(
            csrfToken: "abcdefghijklmnop",
            files: [status]
        )
        let encoded = try LANHTTPJSONCodec.encode(session)
        let json = String(decoding: encoded, as: UTF8.self)

        #expect(try LANHTTPJSONCodec.decode(
            LANFileSessionResponse.self,
            from: encoded
        ) == session)
        for forbidden in ["itemID", "blobID", "sha256", "memberID", "date"] {
            #expect(!json.contains(forbidden))
        }
        #expect(json.contains("\"files\""))
        #expect(json.contains("\"remoteFileID\""))
    }

    @Test
    func genericMutationResponsesAndRejectionsAreDeterministic() throws {
        #expect(String(
            decoding: try LANHTTPJSONCodec.encode(LANFileSavedResponse()),
            as: UTF8.self
        ) == "{\"outcome\":\"saved\"}")
        #expect(String(
            decoding: try LANHTTPJSONCodec.encode(LANFileCancelResponse()),
            as: UTF8.self
        ) == "{\"outcome\":\"cancelled\"}")
        #expect(String(
            decoding: try LANHTTPJSONCodec.encode(
                LANHTTPRejectionResponse(error: .sessionEnded, retryable: false)
            ),
            as: UTF8.self
        ) == "{\"error\":\"sessionEnded\",\"retryable\":false}")
    }
}
