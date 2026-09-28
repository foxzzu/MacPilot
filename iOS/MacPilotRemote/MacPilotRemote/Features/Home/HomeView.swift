import MacPilotRemoteProtocol
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The four remote actions. No confirmation dialogs: an authenticated, encrypted
/// connection is already in place.
struct HomeView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Binding var selectedTab: RootTab

    /// Adaptive so the action grid fills an iPad's width instead of
    /// stretching two columns across it; on a phone it still lands on two.
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    @State private var trackpadModel: RemoteTrackpadModel?
    @State private var trackpadVisible = false
    @State private var desktopVisible = false
    /// Text key of why the trackpad entry refused a tap, shown as an alert.
    @State private var trackpadHintKey: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    deviceCard
                    remoteToolsRow
                    actionGrid
                    // Hidden entirely on a Mac that predates the capability:
                    // the trackpad explains itself on tap, but a whole dead
                    // section would just be noise.
                    if !appModel.connectionState.isConnected || appModel.supportsDockGroups {
                        dockGroupsPanel
                    }
                    levelsPanel
                    messageBanner
                    if !appModel.connectionState.isConnected {
                        disconnectedPanel
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            // The trackpad page must own the whole screen: while it is up the
            // tab bar goes away, otherwise it floats over the touch surface.
            .toolbar((trackpadVisible || desktopVisible) ? .hidden : .visible, for: .tabBar)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(appModel.text("tabHome"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay {
            // The trackpad page lives above everything and flips out of the
            // device card; it stays mounted through the exit animation so the
            // end command and the reverse flip both finish. The background
            // inside extends under the system chrome; the content itself
            // respects the safe areas.
            if trackpadVisible, let trackpadModel {
                if desktopVisible {
                    RemoteDesktopView(trackpad: trackpadModel, onClose: closeTrackpad)
                } else {
                    TrackpadContainerView(model: trackpadModel, onClose: closeTrackpad)
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: appModel.connectionGeneration) { _, _ in
            trackpadModel?.connectionReplaced()
        }
        .onChange(of: appModel.connectionState) { _, _ in
            trackpadModel?.connectionStateChanged(appModel.connectionState)
        }
        .alert(
            appModel.text("trackpadEntry"),
            isPresented: Binding(
                get: { trackpadHintKey != nil },
                set: { if !$0 { trackpadHintKey = nil } }
            ),
            actions: {
                Button(appModel.text("trackpadDone")) { trackpadHintKey = nil }
            },
            message: {
                Text(trackpadHintKey.map { appModel.text($0) } ?? "")
            }
        )
    }

    private var desktopEntry: some View {
        Button {
            guard appModel.connectionState.isConnected, appModel.supportsRealtimeInput else {
                trackpadHintKey = "trackpadNotConnected"; return
            }
            desktopVisible = true
            openTrackpad()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "display").font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appModel.text("desktopTitle")).font(.headline)
                    Text(appModel.text("desktopHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var remoteToolsRow: some View {
        HStack(spacing: 14) {
            desktopEntry
            trackpadRow
        }
    }

    // MARK: - Trackpad

    private func openTrackpad() {
        guard trackpadModel == nil else { return }
        guard appModel.connectionState.isConnected else { return }
        let model = RemoteTrackpadModel()
        trackpadModel = model
        trackpadVisible = true
        model.open(appModel: appModel)
    }

    private func closeTrackpad() {
        trackpadModel?.close()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.34))
            desktopVisible = false
            trackpadVisible = false
            trackpadModel = nil
        }
    }

    // MARK: - Device card

    /// The device switcher stays in its own compact card so the two remote
    /// tools can share a balanced row below it.
    private var deviceCard: some View {
        deviceSwitcher
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var deviceSwitcher: some View {
        Menu {
            ForEach(appModel.pairedMacs) { mac in
                Button {
                    appModel.connect(to: mac)
                } label: {
                    Label(
                        "\(mac.name) · \(presenceLabel(for: mac))",
                        systemImage: appModel.selectedMacID == mac.id ? "checkmark.circle.fill" : "desktopcomputer"
                    )
                }
            }
            if !appModel.pairedMacs.isEmpty { Divider() }
            Button {
                selectedTab = .devices
            } label: {
                Label(appModel.text("manageMacs"), systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "desktopcomputer")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appModel.pairedMacs.isEmpty ? appModel.text("chooseMac") : appModel.activeMacName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(appModel.text(appModel.connectionState.titleKey))
                        if let latency = appModel.latencyMs, appModel.connectionState.isConnected {
                            Text("·")
                            Text(appModel.text("latency", latency))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(appModel.text("switchMacAccessibility", appModel.activeMacName))
    }

    /// The trackpad entry. Only a live session whose Mac advertised the
    /// realtime channel may open it; any other tap explains itself with an
    /// alert — a Mac that predates the channel would drop the connection if
    /// `beginRealtimeInput` reached it, so it is told to update instead.
    private var trackpadRow: some View {
        Button(action: handleTrackpadTap) {
            VStack(spacing: 4) {
                Image(systemName: "computermouse")
                    .font(.body)
                    .foregroundStyle(trackpadReady ? Color.accentColor : Color.secondary)
                Text(appModel.text("trackpadEntry"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appModel.text("trackpadEntry"))
        .accessibilityHint(trackpadSubtitle)
    }

    private func handleTrackpadTap() {
        guard trackpadReady else {
            trackpadHintKey = trackpadSubtitle
            return
        }
        openTrackpad()
    }

    private var trackpadReady: Bool {
        appModel.connectionState.isConnected && appModel.supportsRealtimeInput
    }

    private var trackpadSubtitle: String {
        if !appModel.connectionState.isConnected {
            return appModel.text("trackpadNotConnected")
        }
        if !appModel.supportsRealtimeInput {
            return appModel.text("trackpadNeedsMacUpdate")
        }
        return appModel.text("trackpadEntryHint")
    }

    private func presenceLabel(for mac: PairedMac) -> String {
        switch appModel.status(for: mac) {
        case .connected: appModel.text("connectedLabel")
        case .online: appModel.text("online")
        case .offline: appModel.text("offline")
        }
    }

    private var statusColor: Color {
        switch appModel.connectionState {
        case .connected: return .green
        case .connecting, .authenticating, .pairing, .discovering, .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    // MARK: - Actions

    /// The four remote actions, paired by intent: the first row takes the Mac
    /// away (lock, black), the second brings it back (light the screen, wake and
    /// unlock).
    ///
    /// There is deliberately no plain "unlock" button: the Mac's unlock path
    /// wakes the display itself when it is off, so a separate action was the same
    /// thing with a second way to get it wrong.
    private var actionGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            actionButton(.displayOff, titleKey: "actionDisplayOff", systemImage: "moon.fill", tint: .indigo)
            actionButton(.wakeDisplay, titleKey: "actionWakeDisplay", systemImage: "sun.max.fill", tint: .yellow)
            actionButton(.lockScreen, titleKey: "actionLock", systemImage: "lock.fill", tint: .blue)
            actionButton(.wakeAndUnlock, titleKey: "actionWakeAndUnlock", systemImage: "sunrise.fill", tint: .orange)
        }
    }

    private func actionButton(
        _ command: RemoteCommand,
        titleKey: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        let isRunning = appModel.runningCommand == command
        let enabled = appModel.connectionState.isConnected && appModel.runningCommand == nil
        return Button {
            appModel.beginCommand(command)
            Task { await appModel.perform(command) }
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    if isRunning {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 30, weight: .semibold))
                    }
                }
                .frame(height: 34)
                Text(appModel.text(titleKey))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(enabled ? 0.28 : 0.10))
            )
            .foregroundStyle(enabled ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(appModel.text(titleKey))
    }

    // MARK: - Dock groups

    private var dockGroupsPanel: some View {
        DockGroupsPanel()
    }

    // MARK: - Output levels

    /// Brightness and volume, read from the same `MacRemoteState` the rest of
    /// the screen uses.
    ///
    /// A level the Mac did not report is not shown at all: an external monitor
    /// with no controllable backlight, or a Mac with no output device, both mean
    /// a slider that cannot work. The card says so instead of offering one.
    private var levelsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appModel.text("levelsTitle"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if !appModel.connectionState.isConnected {
                hint(appModel.text("levelsNotConnected"))
            } else if appModel.macState == nil {
                // The state rides along with the first response after the
                // handshake; nothing useful to say for that one round trip.
                hint(appModel.text("levelsUnavailableShort"))
            } else if appModel.hasLevelControls {
                ForEach(RemoteLevelKind.allCases, id: \.self) { kind in
                    if let value = kind.value(in: appModel.macState) {
                        LevelSliderRow(kind: kind, value: value)
                    }
                }
            } else {
                hint(appModel.text("levelsUnavailable"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Messages

    @ViewBuilder
    private var messageBanner: some View {
        if let errorKey = appModel.errorKey {
            banner(text: appModel.text(errorKey), systemImage: "exclamationmark.triangle.fill", tint: .orange)
        } else if let infoKey = appModel.infoKey {
            banner(text: infoText(infoKey), systemImage: "checkmark.circle.fill", tint: .green)
        }
    }

    /// The missing-apps info carries the failed names with it, so it reads like
    /// a sentence instead of a bare "done".
    private func infoText(_ key: String) -> String {
        if key == "dockGroupLaunchMissing", !appModel.dockGroupsMissingApps.isEmpty {
            return appModel.text(key, appModel.dockGroupsMissingApps.joined(separator: "、"))
        }
        return appModel.text(key)
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
            Button {
                appModel.clearMessages()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    // MARK: - Disconnected

    /// The Mac Bonjour can see but that has not been paired yet.
    private var unpairedMac: DiscoveredMac? {
        appModel.discoveredMacs.first { !appModel.store.isPaired(id: $0.id) }
    }

    /// Explains why no Mac is reachable. Order matters: a discovered-but-unpaired
    /// Mac is the common case and must not be reported as "not found", which
    /// made a working browse look like a broken network.
    private var disconnectedTitle: String {
        if unpairedMac != nil { return appModel.text("foundUnpaired") }
        return appModel.text("noMac")
    }

    private var disconnectedDetail: String {
        if appModel.localNetworkDenied {
            return appModel.text("localNetworkHint")
        }
        if let mac = unpairedMac {
            return appModel.text("foundUnpairedDetail", mac.name)
        }
        if appModel.unrecognizedServiceCount > 0 {
            return appModel.text("unrecognizedServiceHint")
        }
        return appModel.text("noMacDetail")
    }

    private var disconnectedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(disconnectedTitle).font(.headline)
            Text(disconnectedDetail).font(.subheadline).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if unpairedMac != nil {
                    Button(appModel.text("goToPairing")) { selectedTab = .devices }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(appModel.text("retry")) { appModel.retry() }
                        .buttonStyle(.borderedProminent)
                }
                if appModel.localNetworkDenied {
                    Button(appModel.text("openSystemSettings")) { openSystemSettings() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

extension RemoteAppModel {
    /// `nil` when this Mac has no mute control at all, as opposed to a device
    /// that is simply not muted.
    var volumeMuted: Bool? { macState?.volumeMuted?.boolValue }
}

/// One brightness or volume row.
///
/// The slider keeps its own draft while the finger is down: the Mac's answer
/// arrives a round trip later, and letting that value write back mid-drag would
/// fight the user. Every change is handed to the model, which coalesces the
/// drag into a single in-flight request ending on the value the user let go of.
private struct LevelSliderRow: View {
    @EnvironmentObject private var appModel: RemoteAppModel

    let kind: RemoteLevelKind
    /// The value the Mac last reported, used whenever the finger is up.
    let value: Double

    @State private var draft: Double = 0
    @State private var isEditing = false

    private var isMuted: Bool {
        kind == .volume && appModel.volumeMuted == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "speaker.slash.fill" : kind.iconName)
                    .font(.subheadline)
                    .frame(width: 20)
                    .foregroundStyle(isMuted ? Color.orange : Color.accentColor)
                Text(appModel.text(kind.labelKey))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("\(Int((draft * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if kind == .volume, appModel.volumeMuted != nil {
                    muteButton
                }
            }

            Slider(value: $draft, in: 0...1, step: 0.01) { editing in
                isEditing = editing
                // The release is sent explicitly so a drag that ends between two
                // coalesced requests still lands on its final value.
                if !editing { send(draft) }
            }
            .accessibilityLabel(appModel.text(kind.labelKey))
            .accessibilityValue("\(Int((draft * 100).rounded()))%")
        }
        .onAppear { draft = value }
        .onChange(of: draft) { _, newValue in
            guard isEditing else { return }
            send(newValue)
        }
        .onChange(of: value) { _, newValue in
            guard !isEditing else { return }
            draft = newValue
        }
    }

    private var muteButton: some View {
        Button {
            appModel.setLevel(kind, value: draft, muted: !isMuted)
            Haptics.impact()
        } label: {
            Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.subheadline)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appModel.text(isMuted ? "unmute" : "mute"))
    }

    /// Raising the volume clears mute, exactly like the Mac's own volume keys;
    /// dragging to silence leaves the mute state alone.
    private func send(_ newValue: Double) {
        let muted: Bool? = kind == .volume && newValue > 0 ? false : nil
        appModel.setLevel(kind, value: newValue, muted: muted)
    }
}

/// The Mac's Dock groups, launchable from the couch: tapping a group opens
/// every member on the Mac, expanding it offers per-app launches.
///
/// Same honesty rules as the levels panel: the section only appears when the
/// Mac advertised the capability, and the rows only ever show what the Mac's
/// own snapshot reported — the phone never guesses running state.
private struct DockGroupsPanel: View {
    @EnvironmentObject private var appModel: RemoteAppModel

    @State private var expandedGroupID: String?

    private var isConnected: Bool { appModel.connectionState.isConnected }
    private var isBusy: Bool { appModel.launchingDockGroupID != nil || appModel.launchingDockAppID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(appModel.text("dockGroupsTitle"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if isConnected {
                    Button {
                        appModel.refreshDockGroups()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(appModel.text("dockGroupRefresh"))
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private var content: some View {
        if !isConnected {
            hint(appModel.text("dockGroupsNotConnected"))
        } else if let groups = appModel.dockGroupsSnapshot?.groups {
            if groups.isEmpty {
                hint(appModel.text("dockGroupsEmpty"))
            } else {
                VStack(spacing: 10) {
                    ForEach(groups) { group in
                        groupRow(group)
                    }
                }
            }
        } else {
            // The first fetch is still in the air, or it failed; the header
            // refresh button is the retry path either way.
            hint(appModel.text("dockGroupsUnavailable"))
        }
    }

    private func groupRow(_ group: RemoteDockGroupSummary) -> some View {
        let runningCount = group.apps.filter(\.isRunning).count
        let isExpanded = expandedGroupID == group.id
        let canExpand = !group.apps.isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                groupIcon(group)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(appModel.text("dockGroupAppsRunning", group.apps.count, runningCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                launchGroupButton(group)
                if canExpand {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedGroupID = isExpanded ? nil : group.id
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(appModel.text(canExpand ? "dockGroupExpandHint" : "dockGroupEmptyHint"))

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.apps) { app in
                        appRow(group, app)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private func launchGroupButton(_ group: RemoteDockGroupSummary) -> some View {
        Button {
            appModel.launchDockGroup(id: group.id)
        } label: {
            ZStack {
                if appModel.launchingDockGroupID == group.id {
                    ProgressView()
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(group.apps.isEmpty ? Color.secondary : Color.accentColor)
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(group.apps.isEmpty || isBusy)
        .accessibilityLabel(appModel.text("dockGroupLaunch", group.name))
    }

    private func appRow(_ group: RemoteDockGroupSummary, _ app: RemoteDockGroupAppSummary) -> some View {
        Button {
            appModel.launchDockGroupApp(groupID: group.id, appID: app.id)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(app.isRunning ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(app.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ZStack {
                    if appModel.launchingDockAppID == app.id {
                        ProgressView()
                    } else {
                        Image(systemName: app.isRunning ? "arrow.uturn.forward.circle" : "arrow.up.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(appModel.text("dockGroupLaunchApp", app.name))
    }

    @ViewBuilder
    private func groupIcon(_ group: RemoteDockGroupSummary) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
            switch group.iconSource {
            case .symbol where Self.symbolExists(group.iconValue):
                Image(systemName: group.iconValue)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            case .emoji:
                Text(group.iconValue)
                    .font(.system(size: 16))
            default:
                // Composite and custom images live on the Mac; the placeholder
                // says "a group of apps" without pretending to be the real icon.
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 36, height: 36)
    }

    /// The Mac's symbol catalog can be newer than the phone's; an unknown
    /// name falls back to the placeholder instead of rendering blank.
    private static func symbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #else
        false
        #endif
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
