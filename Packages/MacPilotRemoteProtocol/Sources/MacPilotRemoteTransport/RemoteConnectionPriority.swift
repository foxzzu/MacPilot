import Foundation

/// Physical paths, independent of how their endpoint was discovered.
public enum RemoteConnectionMethod: String, CaseIterable, Sendable {
    case localNetwork
    case awdl
    case bluetooth

    public var textKey: String { "connectionMethod" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public enum RemoteConnectionPriority {
    public static let defaultOrder: [RemoteConnectionMethod] = [.localNetwork, .awdl, .bluetooth]

    /// Repairs older or malformed preferences without dropping a path.
    public static func normalized(_ values: [String]) -> [RemoteConnectionMethod] {
        var result: [RemoteConnectionMethod] = []
        for value in values {
            if let method = RemoteConnectionMethod(rawValue: value), !result.contains(method) {
                result.append(method)
            }
        }
        return result + defaultOrder.filter { !result.contains($0) }
    }

    public static func shouldReplace(_ current: RemoteConnectionMethod?, with candidate: RemoteConnectionMethod,
                                     order: [RemoteConnectionMethod]) -> Bool {
        guard let current else { return true }
        let complete = normalized(order.map(\.rawValue))
        return complete.firstIndex(of: candidate)! < complete.firstIndex(of: current)!
    }
}
