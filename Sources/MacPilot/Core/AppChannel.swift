import Foundation

enum AppChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta

    var titleKey: String { self == .stable ? "stableChannel" : "betaChannel" }
    var descriptionKey: String { self == .stable ? "stableChannelHint" : "betaChannelHint" }

    static var developmentDefault: Self {
        #if DEBUG
        .beta
        #else
        .stable
        #endif
    }

    static func installed(bundle: Bundle = .main) -> Self {
        (bundle.object(forInfoDictionaryKey: "MacPilotUpdateChannel") as? String)
            .flatMap(Self.init(rawValue:)) ?? BuildInfo.channel
    }
}

typealias UpdateChannel = AppChannel
