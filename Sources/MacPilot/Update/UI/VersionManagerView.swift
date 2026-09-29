import SwiftUI

/// 设置 → 软件更新 → 版本管理。
///
/// 历史版本列表放在独立 Sheet 中，不堆进设置页；加载状态走
/// `ReleaseCatalogState`，与 `SoftwareUpdateState` 完全隔离。
struct VersionManagerSheet: View {
    @ObservedObject private var versionManager: VersionManager
    @ObservedObject private var coordinator: VersionSwitchCoordinator
    @EnvironmentObject private var model: MacPilotModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter: CatalogFilter = .all
    @State private var searchText = ""
    @State private var expandedVersion: String?

    enum CatalogFilter: String, CaseIterable, Identifiable {
        case all, stable, beta
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .all: "versionManagerFilterAll"
            case .stable: "stableChannel"
            case .beta: "betaChannel"
            }
        }
    }

    init(versionManager: VersionManager) {
        _versionManager = ObservedObject(wrappedValue: versionManager)
        _coordinator = ObservedObject(wrappedValue: versionManager.coordinator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            summaryCard
            filterBar
            switch coordinator.phase {
            case .some(let phase): phaseBanner(phase)
            case nil: releaseList
            }
            snapshotsCard
        }
        .padding(30)
        .frame(width: 580, height: 640)
        .task { await versionManager.refresh() }
        .sheet(isPresented: $versionManager.showsConfirmation) { confirmationSheet }
        // lastErrorMessage 已是完整文案；再套一次格式串会出现
        // 「版本切换失败：版本切换失败：…」的重复前缀。
        .alert(
            versionManager.lastErrorMessage ?? "",
            isPresented: Binding(
                get: { versionManager.lastErrorMessage != nil },
                set: { if !$0 { versionManager.lastErrorMessage = nil } }
            )
        ) {
            Button(t("versionManagerRetry")) {
                Task { await versionManager.refresh(forceRefresh: true) }
            }
        }
        .onDisappear { versionManager.cancelConfirmation() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("versionManager")).font(.system(size: 30, weight: .bold))
                Text(t("versionManagerSubtitle")).foregroundStyle(.secondary)
            }
            Spacer()
            // Sheet 没有标题栏，必须提供显式的关闭入口（Esc 同效）。
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text(t("cancel")))
        }
    }

    private var summaryCard: some View {
        SettingsCard {
            HStack(spacing: 24) {
                summaryItem(
                    title: t("versionManagerCurrentInstall"),
                    value: currentVersionText,
                    highlighted: true
                )
                Divider().frame(height: 34)
                summaryItem(
                    title: t("versionManagerLatestStable"),
                    value: latestStableText
                )
                Divider().frame(height: 34)
                summaryItem(
                    title: t("versionManagerLatestBeta"),
                    value: latestBetaText
                )
                Spacer()
                if case .loading = versionManager.catalog.state {
                    ProgressView().controlSize(.small)
                } else {
                    Button(t("versionManagerRefresh")) {
                        Task { await versionManager.refresh(forceRefresh: true) }
                    }
                    .disabled(coordinator.phase != nil)
                }
            }
        }
    }

    private var currentVersionText: String {
        let channel = model.updateChannel == .beta
            ? t("betaChannel")
            : t("stableChannel")
        return "\(versionManager.currentVersion) · \(channel)"
    }

    private var latestStableText: String {
        guard case .loaded(let catalog) = versionManager.catalog.state,
              let latest = catalog.latestStable else { return "" }
        return latest.description
    }

    private var latestBetaText: String {
        guard case .loaded(let catalog) = versionManager.catalog.state,
              let latest = catalog.latestBeta else { return "" }
        return latest.description
    }

    private func summaryItem(title: String, value: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.body, design: .monospaced).weight(highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? Color.primary : Color.secondary)
                .textSelection(.enabled)
        }
    }

    private var filterBar: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(CatalogFilter.allCases) { candidate in
                    Text(t(candidate.titleKey)).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            Spacer()
            TextField(t("versionManagerSearch"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    @ViewBuilder
    private var releaseList: some View {
        switch versionManager.catalog.state {
        case .idle, .loading:
            SettingsCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t("versionManagerLoading")).foregroundStyle(.secondary)
                }
            }
        case .failed(let failure):
            SettingsCard {
                Label(t("versionManagerLoadFailed"), systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.red)
                if let detail = failure.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(t("versionManagerRetry")) {
                    Task { await versionManager.refresh(forceRefresh: true) }
                }
            }
        case .loaded:
            releaseRows
        }
    }

    private var releaseRows: some View {
        ScrollView {
            VStack(spacing: 12) {
                let entries = filteredEntries
                if entries.isEmpty {
                    Text(t("versionManagerEmpty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
                ForEach(entries) { entry in
                    VersionReleaseRow(
                        entry: entry,
                        currentVersion: versionManager.currentVersion,
                        currentChannel: model.updateChannel,
                        language: model.language,
                        isLatestStable: isLatest(entry, .stable),
                        isLatestBeta: isLatest(entry, .beta),
                        isExpanded: expandedVersion == entry.id,
                        isBusy: coordinator.phase != nil,
                        onToggleExpand: {
                            expandedVersion = expandedVersion == entry.id ? nil : entry.id
                        },
                        onInstall: { versionManager.requestInstall(entry) }
                    )
                }
            }
        }
    }

    private var filteredEntries: [CatalogRelease] {
        guard case .loaded(let catalog) = versionManager.catalog.state else { return [] }
        return catalog.releases.filter { entry in
            switch filter {
            case .all: true
            case .stable: entry.channel == .stable
            case .beta: entry.channel == .beta
            }
        }
        .filter { entry in
            guard !searchText.isEmpty else { return true }
            return entry.release.version.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func isLatest(_ entry: CatalogRelease, _ channel: AppChannel) -> Bool {
        guard case .loaded(let catalog) = versionManager.catalog.state else { return false }
        return channel == .stable
            ? catalog.latestStable == entry.release.version
            : catalog.latestBeta == entry.release.version
    }

    private var snapshotsCard: some View {
        ConfigurationSnapshotsView(
            versionManager: versionManager,
            language: model.language,
            isBusy: coordinator.phase != nil
        )
    }

    @ViewBuilder
    private var confirmationSheet: some View {
        if let entry = versionManager.pendingInstall {
            VersionSwitchConfirmationView(
                entry: entry,
                restoreRecord: versionManager.pendingRestoreRecord,
                currentVersion: versionManager.currentVersion,
                currentChannel: model.updateChannel
            )
            .environmentObject(model)
        }
    }

    private func phaseBanner(_ phase: VersionSwitchPhase) -> some View {
        SettingsCard {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(t(phaseKey(phase))).foregroundStyle(.secondary)
            }
        }
    }

    private func phaseKey(_ phase: VersionSwitchPhase) -> String {
        switch phase {
        case .downloading: "versionManagerPhaseDownloading"
        case .verifyingPackage: "versionManagerPhaseVerifying"
        case .preparingConfiguration: "versionManagerPhasePreparing"
        case .snapshotting: "versionManagerPhaseSnapshotting"
        case .readyToInstall: "versionManagerPhaseReady"
        case .replacingApplication: "versionManagerPhaseReplacing"
        case .awaitingRelaunch: "versionManagerPhaseAwaiting"
        case .runningTarget, .completed, .failed: "versionManagerPhaseAwaiting"
        }
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: model.language, arguments: arguments)
    }
}

/// 单个历史版本行：版本号、通道、徽标、日期、展开说明与安装按钮。
struct VersionReleaseRow: View {
    let entry: CatalogRelease
    let currentVersion: String
    let currentChannel: AppChannel
    let language: AppLanguage
    let isLatestStable: Bool
    let isLatestBeta: Bool
    let isExpanded: Bool
    let isBusy: Bool
    let onToggleExpand: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.release.version.description)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text(channelTitle)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeBackground, in: Capsule())
                badges
                Spacer()
                actionButton
            }
            HStack(spacing: 8) {
                if let publishedAt = entry.release.publishedAt {
                    Text(publishedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if entry.compatibility == nil {
                    Text(t("versionManagerCompatibilityUnknown"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if entry.compatibilityState.isKnownIncompatible {
                    Text(t("versionManagerCompatibilityIncompatible"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if isExpanded {
                    Button {
                        onToggleExpand()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                } else if !entry.release.releaseNotes.isEmpty {
                    Button {
                        onToggleExpand()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }
            if isExpanded, !entry.release.releaseNotes.isEmpty {
                Text(entry.release.releaseNotes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var channelTitle: String {
        entry.channel == .stable ? t("stableChannel") : t("betaChannel")
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }

    @ViewBuilder
    private var badges: some View {
        let relation = entry.relation(to: currentVersion)
        if relation == .current {
            badge(t("versionManagerBadgeCurrent"), color: .accentColor)
        } else if isLatestStable && entry.channel == .stable {
            badge(t("versionManagerBadgeLatestStable"), color: .green)
        } else if isLatestBeta && entry.channel == .beta {
            badge(t("versionManagerBadgeLatestBeta"), color: .orange)
        } else {
            badge(t("versionManagerBadgeHistory"), color: .secondary)
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(color)
    }

    private var badgeBackground: some ShapeStyle {
        entry.channel == .stable
            ? AnyShapeStyle(Color.green.opacity(0.12))
            : AnyShapeStyle(Color.orange.opacity(0.12))
    }

    private var actionButton: some View {
        let relation = entry.relation(to: currentVersion)
        return Button(actionTitle(for: relation), action: onInstall)
            .disabled(relation == .current || isBusy)
            .macPilotProminentButtonStyle(relation != .current)
            .controlSize(.small)
    }

    private func actionTitle(for relation: VersionRelation) -> String {
        switch relation {
        case .current:
            t("versionManagerBadgeCurrent")
        case .newer:
            crossChannelTitle() ?? t("versionManagerUpgradeTo", entry.release.version.description)
        case .older:
            crossChannelTitle() ?? t("versionManagerDowngradeTo", entry.release.version.description)
        }
    }

    /// 跨通道安装优先使用「安装正式版/开发版」措辞（方案第 28 节）。
    private func crossChannelTitle() -> String? {
        switch (currentChannel, entry.channel) {
        case (.beta, .stable):
            t("versionManagerInstallStable", entry.release.version.description)
        case (.stable, .beta):
            t("versionManagerInstallBeta", entry.release.version.description)
        default:
            nil
        }
    }
}

/// 降级保护快照列表（方案第 38 节）。
struct ConfigurationSnapshotsView: View {
    @ObservedObject var versionManager: VersionManager
    let language: AppLanguage
    let isBusy: Bool

    var body: some View {
        if !versionManager.snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("versionManagerProtection")).font(.headline)
                ForEach(versionManager.snapshots) { record in
                    snapshotRow(record)
                }
            }
        }
    }

    private func snapshotRow(_ record: ConfigurationSnapshotManager.SnapshotRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.manifest.sourceAppVersion) → \(record.manifest.targetAppVersion)")
                    .font(.system(.body, design: .monospaced))
                HStack(spacing: 8) {
                    Text(record.manifest.createdAt, style: .date)
                    Text(byteCountFormatter.string(fromByteCount: Int64(record.sizeBytes)))                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            if record.manifest.status == .downgradeActive {
                Text(t("versionManagerActiveProtection"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(statusTitle(record.manifest.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if record.manifest.status == .downgradeActive {
                Button(t("versionManagerRestore")) {
                    versionManager.requestRestore(record)
                }
                .disabled(isBusy || !versionManager.canRestoreActiveSnapshot)
            }
            Button {
                versionManager.reveal(record)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            if record.manifest.status != .downgradeActive {
                Button(role: .destructive) {
                    versionManager.delete(record)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var byteCountFormatter: ByteCountFormatter { Self.byteCountFormatter }

    private func statusTitle(_ status: SnapshotStatus) -> String {
        switch status {
        case .downgradeActive: t("versionManagerActiveProtection")
        case .ready: t("versionManagerStatusReady")
        case .restored: t("versionManagerStatusRestored")
        case .archived: t("versionManagerStatusCompleted")
        case .corrupted: t("versionManagerStatusCorrupted")
        case .preparing: t("versionManagerPhaseSnapshotting")
        }
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: language, arguments: arguments)
    }
}

/// 降级确认页（方案第 29 节）：完整保护清单 + 兼容性提示，不提供跳过备份。
struct VersionSwitchConfirmationView: View {
    @EnvironmentObject private var model: MacPilotModel
    let entry: CatalogRelease
    let restoreRecord: ConfigurationSnapshotManager.SnapshotRecord?
    let currentVersion: String
    let currentChannel: AppChannel
    @Environment(\.dismiss) private var dismiss

    private var isDowngrade: Bool {
        entry.relation(to: currentVersion) == .older
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isDowngrade ? t("versionManagerConfirmDowngradeTitle") : t("versionManagerConfirmInstallTitle", entry.release.version.description))
                    .font(.system(size: 26, weight: .bold))
                HStack(spacing: 10) {
                    Text(currentVersion).font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.down")
                        .foregroundStyle(isDowngrade ? Color.orange : Color.accentColor)
                    Text(entry.release.version.description)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    channelChangeBadge
                }
            }

            SettingsCard {
                Text(t("versionManagerProtectTitle")).font(.headline)
                protectionRow("gearshape.fill", t("versionManagerProtectSettings"))
                protectionRow("keyboard", t("versionManagerProtectShortcuts"))
                protectionRow("menubar.dock.rectangle", t("versionManagerProtectDockGroups"))
                protectionRow("cursorarrow.click.2", t("versionManagerProtectRightClick"))
                protectionRow("switch.2", t("versionManagerProtectPreferences"))
                protectionRow("iphone.gen3", t("versionManagerProtectRemotePairing"))
                protectionRow("lock.shield", t("versionManagerProtectUnlockPassword"))
                Text(t("versionManagerClipboardNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entry.compatibility == nil || entry.compatibilityState.isKnownIncompatible {
                Text(t("versionManagerIncompatibleNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if restoreRecord != nil {
                Text(t("versionManagerRestoreNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            HStack {
                Button(t("cancel")) {
                    model.versionManager.cancelConfirmation()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(proceedTitle) {
                    model.versionManager.confirmPendingAction()
                }
                .keyboardShortcut(.defaultAction)
                .macPilotProminentButtonStyle()
            }
        }
        .padding(30)
        .frame(width: 470)
    }

    @ViewBuilder
    private var channelChangeBadge: some View {
        switch (currentChannel, entry.channel) {
        case (.stable, .beta):
            Text(t("versionManagerChannelStableToBeta")).font(.caption).foregroundStyle(.secondary)
        case (.beta, .stable):
            Text(t("versionManagerChannelBetaToStable")).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var proceedTitle: String {
        isDowngrade ? t("versionManagerConfirmProceedDowngrade") : t("versionManagerConfirmProceed")
    }

    private func protectionRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16)
            Text(title).font(.subheadline)
        }
    }

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        AppText.value(key, language: model.language, arguments: arguments)
    }
}

extension View {
    /// 只在需要强调的按钮上使用 prominent 样式。
    @ViewBuilder
    func macPilotProminentButtonStyle(_ prominent: Bool) -> some View {
        if prominent {
            self.macPilotProminentButtonStyle()
        } else {
            self
        }
    }
}
