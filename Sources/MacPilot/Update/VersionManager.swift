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
    @Published var pendingConfigurationRestoreRecord: ConfigurationSnapshotManager.SnapshotRecord?
    @Published var showsConfigurationRestoreConfirmation = false
    @Published var isRestoringConfiguration = false
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

    /// 任意 ready 快照的手动恢复：不切换版本，重启后由启动流程回放该快照
    /// 的全部配置。恢复前自动为当前状态创建保护快照，恢复本身可撤销。
    func requestConfigurationRestore(_ record: ConfigurationSnapshotManager.SnapshotRecord) {
        lastErrorMessage = nil
        pendingConfigurationRestoreRecord = record
        showsConfigurationRestoreConfirmation = true
    }

    func cancelConfigurationRestoreConfirmation() {
        pendingConfigurationRestoreRecord = nil
        showsConfigurationRestoreConfirmation = false
    }

    func confirmConfigurationRestore() {
        guard let record = pendingConfigurationRestoreRecord else {
            showsConfigurationRestoreConfirmation = false
            return
        }
        pendingConfigurationRestoreRecord = nil
        showsConfigurationRestoreConfirmation = false
        isRestoringConfiguration = true
        do {
            try coordinator.performConfigurationRestore(of: record.manifest)
            // 重启由 AppSelfRelauncher 的守望进程执行；这里正常退出应用。
            // 成功路径不解除冻结：写入保持关闭直到进程退出，重启后的新
            // 实例在启动时回放恢复点。
            NSApp.terminate(nil)
            // 若终止被拦截，兜底解冻，让用户继续使用当前配置。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.isRestoringConfiguration else { return }
                self.isRestoringConfiguration = false
                self.coordinator.unfreezeAfterRestore()
            }
        } catch {
            isRestoringConfiguration = false
            DiagnosticLog.write("SoftwareUpdate", "Configuration restore failed: \(String(describing: error))")
            lastErrorMessage = AppText.value(
                "versionManagerRestoreConfigurationFailed",
                language: model?.language ?? .system,
                String(describing: error)
            )
        }
        reloadSnapshots()
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
