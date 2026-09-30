import Foundation

public enum FinderSyncRegistration {
    public static let extensionBundleIdentifier = "com.misswell.macpilot.finder-sync"

    public static func withSuspendedElection(
        wasEnabled: Bool,
        execute: ([String]) throws -> Void,
        restorationFailed: (Error) -> Void = { _ in },
        operation: () throws -> Void
    ) throws {
        guard wasEnabled else {
            try operation()
            return
        }
        try execute(["-e", "ignore", "-i", extensionBundleIdentifier])
        defer {
            do {
                try execute(["-e", "use", "-i", extensionBundleIdentifier])
            } catch {
                restorationFailed(error)
            }
        }
        try operation()
    }

    public static func queryArguments(includeAllVersions: Bool = false) -> [String] {
        var arguments = ["-m", "-v", "-p", "com.apple.FinderSync", "-i", extensionBundleIdentifier]
        if includeAllVersions { arguments += ["-A", "-D"] }
        return arguments
    }

    /// Used once after a missing startup heartbeat. A disabled system
    /// extension stays disabled; stale versions are queried only for cleanup.
    public static func recoverIfEnabled(
        at applicationURL: URL,
        execute: ([String]) throws -> String
    ) throws -> Bool {
        let election = try execute(queryArguments())
        guard isElectedForUse(in: election) else { return false }
        let inventory = try execute(queryArguments(includeAllVersions: true))
        var restorationError: Error?
        try withSuspendedElection(
            wasEnabled: true,
            execute: { _ = try execute($0) },
            restorationFailed: { restorationError = $0 },
            operation: {
                for arguments in registrationArguments(
                    for: applicationURL,
                    registeredExtensionPaths: registeredExtensionPaths(in: inventory),
                    restoreEnabledElection: false
                ) {
                    _ = try execute(arguments)
                }
            }
        )
        if let restorationError { throw restorationError }
        return true
    }

    public static func registeredExtensionPaths(in plugInKitOutput: String) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        for rawLine in plugInKitOutput.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.contains(extensionBundleIdentifier) else { continue }

            let path: String
            if let separator = line.lastIndex(of: "\t") {
                path = String(line[line.index(after: separator)...])
            } else if let slash = line.firstIndex(of: "/") {
                path = String(line[slash...])
            } else {
                continue
            }

            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPath.hasSuffix(".appex"), seen.insert(trimmedPath).inserted else { continue }
            paths.append(trimmedPath)
        }

        return paths
    }

    public static func isElectedForUse(in plugInKitOutput: String) -> Bool {
        plugInKitOutput.split(whereSeparator: \.isNewline).contains { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("+") && line.contains(extensionBundleIdentifier)
        }
    }

    public static func registrationArguments(
        for applicationURL: URL,
        registeredExtensionPaths: [String] = [],
        restoreEnabledElection: Bool
    ) -> [[String]] {
        let extensionPath = applicationURL
            .appendingPathComponent("Contents/PlugIns/FinderSync.appex")
            .path

        var pathsToRemove: [String] = []
        var seen = Set<String>()
        for path in registeredExtensionPaths + [extensionPath] {
            let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            pathsToRemove.append(path)
        }

        var arguments = pathsToRemove.map { ["-r", $0] }
        arguments.append(["-a", extensionPath])
        if restoreEnabledElection {
            arguments.append([
                "-e", "use", "-i", extensionBundleIdentifier
            ])
        }
        return arguments
    }
}
