import Foundation
import MacPilotDockGroupsCore
import MacPilotRemoteProtocol

/// The Dock group surface the remote server may reach. A protocol rather than
/// `DockGroupsModel` itself so the router is testable with a stub and the
/// remote code never couples to the feature's runtime.
@MainActor
protocol RemoteDockGroupsHosting: AnyObject {
    /// `nil` when the Dock Groups feature is off on this Mac, so the phone
    /// hides its section instead of offering controls that cannot work.
    func remoteSnapshot() async -> RemoteDockGroupsSnapshot?

    /// Launches one member (`appID` set) or every member of a group. Running
    /// members are activated, matching the Dock helper's semantics.
    func remoteLaunch(groupID: String, appID: UUID?) async -> RemoteDockGroupLaunchOutcome
}

enum RemoteDockGroupLaunchOutcome {
    /// The launch ran; the snapshot reflects the group list afterwards and
    /// names the members that could not be resolved or launched.
    case snapshot(RemoteDockGroupsSnapshot)
    /// The group or the requested member does not exist (or the feature is
    /// off) — the router answers `invalidMessage`.
    case groupNotFound
}

/// Bridges `DockGroupsModel` to the remote protocol. Launches through the same
/// `AppLaunchService` the Dock helper uses, so the phone can never do anything
/// the Mac's own UI could not.
@MainActor
final class DockGroupsRemoteHost: RemoteDockGroupsHosting {
    private let model: DockGroupsModel

    init(model: DockGroupsModel) {
        self.model = model
    }

    func remoteSnapshot() async -> RemoteDockGroupsSnapshot? {
        guard model.settings.isEnabled else { return nil }
        return RemoteDockGroupsSnapshot(groups: model.groups.map(Self.summary(for:)))
    }

    func remoteLaunch(groupID: String, appID: UUID?) async -> RemoteDockGroupLaunchOutcome {
        guard model.settings.isEnabled, let group = model.groups.first(where: { $0.id == groupID }) else {
            return .groupNotFound
        }
        let targets: [DockGroupApp]
        if let appID {
            guard let app = group.apps.first(where: { $0.id == appID }) else {
                return .groupNotFound
            }
            targets = [app]
        } else {
            targets = group.apps
        }

        var missing: [String] = []
        for app in targets {
            do {
                try await AppLaunchService.open(app)
            } catch {
                missing.append(app.name)
            }
        }
        return .snapshot(
            RemoteDockGroupsSnapshot(
                groups: model.groups.map(Self.summary(for:)),
                missingApps: missing.isEmpty ? nil : missing
            )
        )
    }

    private static func summary(for group: DockGroup) -> RemoteDockGroupSummary {
        RemoteDockGroupSummary(
            id: group.id,
            name: group.name,
            iconSource: RemoteDockGroupIconSource(rawValue: group.icon.source.rawValue) ?? .composite,
            iconValue: group.icon.value,
            apps: group.apps.map { app in
                RemoteDockGroupAppSummary(
                    id: app.id,
                    name: app.name,
                    isRunning: AppLaunchService.isRunning(
                        bundleIdentifier: app.bundleIdentifier,
                        url: URL(fileURLWithPath: app.path)
                    )
                )
            }
        )
    }
}
