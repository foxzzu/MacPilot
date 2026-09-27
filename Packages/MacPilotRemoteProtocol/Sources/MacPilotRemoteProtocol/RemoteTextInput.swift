import Foundation

/// Committed phone keyboard input. Provisional IME composition never leaves
/// the phone. The payload rides the authenticated, encrypted command channel.
public enum RemoteTextInputOperation: Codable, Sendable, Equatable {
    case insert(String)
    case deleteBackward
    case returnKey

    public func encoded() throws -> Data {
        if case let .insert(text) = self {
            guard !text.isEmpty, text.utf16.count <= 256 else {
                throw RemoteProtocolError.invalidMessage
            }
        }
        return try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data?) throws -> Self {
        guard let data, data.count <= 2_048,
              let operation = try? JSONDecoder().decode(Self.self, from: data) else {
            throw RemoteProtocolError.invalidMessage
        }
        if case let .insert(text) = operation {
            guard !text.isEmpty, text.utf16.count <= 256 else {
                throw RemoteProtocolError.invalidMessage
            }
        }
        return operation
    }
}
