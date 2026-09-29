import AppKit
import Foundation

/// Model behind the Version Manager sheet. Owns the release catalog, the
/// snapshot list and the confirmation flow; the actual switch is delegated to
/// `VersionSwitchCoordinator`.
@MainActor
final class VersionManager: ObservableObject {
    let catalog: ReleaseCatalogService
    let coordinator: VersionSwitchCoordinator
    let snapshotManager: ConfigurationSnapshotManager

    @Published private(set) var snapshots: [ConfigurationSnapshotManager.SnapshotRecord] = []
    @Published var lastErrorMessage: String?
    @Published var pendingInstall: CatalogRelease?
    @Published var pendingRestoreRecord: ConfigurationSnapshotManager.SnapshotRecord?
    @Published var showsConfirmation = false

    private weak var model: MacPilotModel?

    init(
        model: MacPilotModel?,
        catalog: ReleaseCatalogService,
        coordinator: VersionSwitchCoordinator,
        snapshotManager: ConfigurationSnapshotManager
    ) {
        self.model = model
        self.catalog = catalog
        self.coordinator = coordinator
        self.snapshotManager = snapshotManager
        reloadSnapshots()
    }

    var currentVersion: String {
        model?.currentVersionForUpdate ?? AppVersionInfo.current().version
    }

    func refresh(forceRefresh: Bool = false) async {
        await catalog.load(forceRefresh: forceRefresh)
        reloadSnapshots()
    }

    func reloadSnapshots() {
        snapshots = snapshotManager.loadSnapshots()
    }

    var activeSnapshot: ConfigurationSnapshotManager.SnapshotRecord? {
        snapshots.first { $0.manifest.status == .downgradeActive }
    }

    // MARK: - Install actions

    func requestInstall(_ entry: CatalogRelease) {
        lastErrorMessage = nil
        pendingRestoreRecord = nil
        pendingInstall = entry
        showsConfirmation = true
    }

    /// "恢复降级前配置": switches back to the snapshot's source version and
    /// replays its configuration at that launch. Needs the source release to
    /// still be installable from the catalog and to support the Version
    /// Manager (otherwise the restore request could never be consumed).
    func requestRestore(_ record: ConfigurationSnapshotManager.SnapshotRecord) {
        lastErrorMessage = nil
        guard let catalogEntry = sourceRelease(for: record.manifest) else {
            lastErrorMessage = AppText.value(
                "versionManagerRestoreSourceMissing",
                language: model?.language ?? .system,
                record.manifest.sourceAppVersion
            )
            return
        }
        pendingInstall = catalogEntry
        pendingRestoreRecord = record
        showsConfirmation = true
    }

    func cancelConfirmation() {
        pendingInstall = nil
        pendingRestoreRecord = nil
        showsConfirmation = false
    }

    func confirmPendingAction() {
        guard let entry = pendingInstall else {
            showsConfirmation = false
            return
        }
        let restoreRecord = pendingRestoreRecord
        pendingInstall = nil
        pendingRestoreRecord = nil
        showsConfirmation = false
        Task {
            await performSwitch(
                to: entry.release,
                compatibility: entry.compatibilityState,
                restoreSnapshot: restoreRecord?.manifest
            )
        }
    }

    var canRestoreActiveSnapshot: Bool {
        guard let activeSnapshot else { return false }
        return sourceRelease(for: activeSnapshot.manifest)?.compatibility?.supportsVersionManager == true
    }

    private func sourceRelease(for manifest: ConfigurationSnapshotManifest) -> CatalogRelease? {
        guard case .loaded(let catalogValue) = catalog.state else { return nil }
        return catalogValue.releases.first {
            $0.release.version.description == manifest.sourceAppVersion
        }
    }

    private func performSwitch(
        to release: SoftwareRelease,
        compatibility: ConfigurationCompatibility,
        restoreSnapshot: ConfigurationSnapshotManifest?
    ) async {
        do {
            try await coordinator.performSwitch(
                to: release,
                intent: installIntent(for: release),
                targetSupportsRestore: restoreSnapshot == nil || compatibility.supportsConfigurationRestore,
                restoreSnapshot: restoreSnapshot
            )
        } catch {
            // 弹窗只承诺「详细原因见诊断日志」，这里必须真的落一条。
            DiagnosticLog.write("SoftwareUpdate", "Version switch failed: \(String(describing: error))")
            lastErrorMessage = AppText.value(
                "versionManagerSwitchFailed",
                language: model?.language ?? .system,
                String(describing: error)
            )
            reloadSnapshots()
        }
    }

    private func installIntent(for release: SoftwareRelease) -> InstallationIntent {
        switch release.relation(to: currentVersion) {
        case .newer: .manualUpgrade
        case .older: .manualDowngrade
        case .current: .channelSwitch
        }
    }

    // MARK: - Snapshot lifecycle

    func delete(_ record: ConfigurationSnapshotManager.SnapshotRecord) {
        do {
            try snapshotManager.delete(record)
        } catch {
            lastErrorMessage = AppText.value(
                "versionManagerSnapshotDeleteFailed",
                language: model?.language ?? .system,
                String(describing: error)
            )
        }
        reloadSnapshots()
    }

    func reveal(_ record: ConfigurationSnapshotManager.SnapshotRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.directory])
    }

    func revealActiveSnapshot() {
        guard let active = activeSnapshot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([active.directory])
    }
}
