// Packaging generates these constants before compilation and restores this
// development fallback afterwards. Never infer the channel from a version.
enum BuildInfo {
    static let channel: AppChannel = .developmentDefault
    static let version = "0.0.0"
}
