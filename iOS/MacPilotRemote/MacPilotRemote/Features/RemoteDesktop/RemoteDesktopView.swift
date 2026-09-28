import MacPilotRemoteProtocol
import SwiftUI

struct RemoteDesktopView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var desktop = RemoteDesktopState()
    @ObservedObject var trackpad: RemoteTrackpadModel
    let onClose: () -> Void
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var landscape = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Image(systemName: "chevron.down") }
                    .accessibilityLabel(appModel.text("trackpadClose"))
                Text(appModel.text("desktopTitle")).font(.headline)
                Spacer()
                if !desktop.displays.isEmpty {
                    Menu {
                        ForEach(desktop.displays) { display in
                            Button(display.name) { desktop.selectDisplay(display.id) }
                        }
                    } label: { Image(systemName: "display.2") }
                    .accessibilityLabel(appModel.text("desktopDisplay"))
                }
                Button { showDiagnostics.toggle() } label: { Image(systemName: "waveform.path") }
                    .accessibilityLabel(appModel.text("desktopDiagnostics"))
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            inputStatus
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    videoArea
                        .frame(height: geometry.size.height * (trackpad.keyboardActive ? 0.85 : 0.45))
                    Divider()
                    if trackpad.keyboardActive {
                        shortcutBar
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TrackpadView(model: trackpad)
                            .allowsHitTesting(trackpad.phase.isActiveLike)
                            .accessibilityLabel(appModel.text("trackpadTitle"))
                    }
                }
            }
            HStack(spacing: 28) {
                Button {
                    landscape.toggle()
                    // Explicit scene rotation; no sensor-driven behavior.
                    trackpad.setOrientation(.top)
                    InterfaceOrientationController.shared.setSupported(landscape ? .landscapeRight : .portrait)
                } label: { Label(appModel.text("desktopOrientation"), systemImage: "arrow.up.and.down") }
                Button {
                    if trackpad.keyboardActive { trackpad.dismissKeyboard() }
                    else { trackpad.requestKeyboard() }
                } label: { Label(appModel.text("desktopKeyboard"), systemImage: "keyboard") }
                .disabled(trackpad.phase != .active)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(appModel.text("trackpadSettings"))
            }
            .font(.subheadline).padding(14)
            RemoteKeyboardInputView(model: trackpad, usesSceneOrientation: true).frame(width: 1, height: 1).accessibilityHidden(true)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            desktop.onKeyboardFocus = { focused in
                if focused { trackpad.dismissKeyboard(); trackpad.requestKeyboard(focused: true) }
                else { trackpad.dismissKeyboard() }
            }
            desktop.open(appModel: appModel)
        }
        .onDisappear { appModel.desktopModifiers = 0; desktop.close() }
        .onChange(of: appModel.connectionGeneration) { _, _ in desktop.connectionChanged() }
        .onChange(of: appModel.connectionState) { _, _ in desktop.connectionChanged() }
        .onChange(of: trackpad.phase) { _, phase in
            if phase == .active, desktop.keyboardFocused { trackpad.requestKeyboard(focused: true) }
        }
        .onChange(of: trackpad.keyboardActive) { _, active in
            if !active { appModel.desktopModifiers = 0 }
        }
        .onChange(of: scenePhase) { _, phase in desktop.sceneChanged(phase) }
        .sheet(isPresented: $showSettings) { TrackpadSettingsView(model: trackpad) }
    }

    @ViewBuilder
    private var inputStatus: some View {
        if let error = trackpad.beginErrorKey {
            inputBanner(appModel.text(error), retry: true)
        } else if trackpad.phase == .disconnected {
            inputBanner(appModel.text("trackpadDisconnected"), retry: true)
        } else if trackpad.phase == .entering || trackpad.phase == .reconnecting {
            inputBanner(appModel.text("stateReconnecting"), retry: false)
        }
    }

    private func inputBanner(_ message: String, retry: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.caption)
            Spacer(minLength: 4)
            if retry {
                Button(appModel.text("retry")) { appModel.retry() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var videoArea: some View {
        GeometryReader { geometry in
            RemoteVideoView(decoder: desktop.decoder)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    guard desktop.showingVideo, trackpad.phase == .active,
                          let display = desktop.displays.first(where: { $0.id == desktop.displayID }) else { return }
                    // Account for letterboxing; bars never become Mac clicks.
                    let scale = min(geometry.size.width / CGFloat(display.width), geometry.size.height / CGFloat(display.height))
                    let width = CGFloat(display.width) * scale
                    let height = CGFloat(display.height) * scale
                    let x = (tap.location.x - (geometry.size.width - width) / 2) / width
                    let y = (tap.location.y - (geometry.size.height - height) / 2) / height
                    guard (0...1).contains(x), (0...1).contains(y) else { return }
                    Task {
                        if await appModel.desktopClick(RemotePointerRequest(displayID: display.id, x: x, y: y)) {
                            trackpad.dismissKeyboard(); trackpad.requestKeyboard()
                        }
                    }
                })
                .overlay {
                    if !desktop.showingVideo {
                        VStack(spacing: 12) {
                            Text(appModel.text(desktop.statusKey)).multilineTextAlignment(.center)
                            if desktop.statusKey != "desktopBluetooth" {
                                Button(appModel.text("retry")) { desktop.retry() }.buttonStyle(.bordered)
                            }
                        }
                        .font(.subheadline).foregroundStyle(.white).padding(24)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showDiagnostics {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appModel.text("desktopFPS", desktop.metrics.fps))
                            if let encode = desktop.encodeMs { Text(appModel.text("desktopEncode", encode)) }
                            Text(appModel.text("desktopDecode", desktop.metrics.decodeMs))
                            Text(appModel.text("desktopNetwork", desktop.metrics.kbps))
                            Text(appModel.text("desktopDropped", desktop.metrics.dropped + desktop.sourceDropped))
                            if let rtt = appModel.latencyMs { Text(appModel.text("desktopRTT", rtt)) }
                        }
                        .font(.caption.monospaced()).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.65)).allowsHitTesting(false)
                    }
                }
        }
    }

    private var shortcutBar: some View {
        HStack(spacing: 14) {
            keyButton("ESC", key: .escape)
            keyButton("TAB", key: .tab)
            modifierButton("CTRL", bit: 1)
            modifierButton("OPTION", bit: 2)
            modifierButton("CMD", bit: 4)
            keyButton("⌫", key: .delete)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
    }

    private func keyButton(_ title: String, key: RemoteKeyRequest.Key) -> some View {
        Button(title) {
            let request = RemoteKeyRequest(key: key, modifiers: appModel.desktopModifiers)
            appModel.desktopModifiers = 0
            Task { await appModel.desktopKey(request) }
        }
    }

    private func modifierButton(_ title: String, bit: UInt8) -> some View {
        Button(title) { appModel.desktopModifiers ^= bit }
            .foregroundStyle(appModel.desktopModifiers & bit == 0 ? Color.secondary : Color.accentColor)
    }
}
