import Foundation
import Testing
@testable import MacPilotRemoteProtocol

struct RemoteTextInputTests {
    @Test func committedUnicodeRoundTrips() throws {
        let operation = RemoteTextInputOperation.insert("你好 👩‍💻")
        #expect(try RemoteTextInputOperation.decoded(from: operation.encoded()) == operation)
        #expect(try RemoteTextInputOperation.decoded(from: RemoteTextInputOperation.deleteBackward.encoded()) == .deleteBackward)
        #expect(try RemoteTextInputOperation.decoded(from: RemoteTextInputOperation.returnKey.encoded()) == .returnKey)
    }

    @Test func oversizedTextIsRejectedOnBothSides() throws {
        let operation = RemoteTextInputOperation.insert(String(repeating: "🙂", count: 129))
        #expect(throws: RemoteProtocolError.self) { try operation.encoded() }
        let raw = try JSONEncoder().encode(operation)
        #expect(throws: RemoteProtocolError.self) { try RemoteTextInputOperation.decoded(from: raw) }
    }

    @Test func emptyAndMalformedPayloadsAreRejected() throws {
        #expect(throws: RemoteProtocolError.self) { try RemoteTextInputOperation.insert("").encoded() }
        #expect(throws: RemoteProtocolError.self) { try RemoteTextInputOperation.decoded(from: nil) }
        #expect(throws: RemoteProtocolError.self) { try RemoteTextInputOperation.decoded(from: Data("{}".utf8)) }
    }
}
