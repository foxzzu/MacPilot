import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network
import SwiftUI

@MainActor
final class RemoteDesktopState: ObservableObject {
    @Published private(set) var decoder = RemoteVideoDecoder()
    @Published private(set) var metrics = RemoteVideoMetrics()
    @Published private(set) var statusKey = "stateConnecting"
    @Published private(set) var showingVideo = false
    @Published private(set) var keyboardFocused = false
    @Published private(set) var displays: [RemoteDisplayInfo] = []
    @Published private(set) var displayID: UInt32?
    @Published private(set) var encodeMs: Double?
    @Published private(set) var sourceDropped = 0
    var onKeyboardFocus: ((Bool) -> Void)?
    private var transport: RemoteVideoTransport?
    private weak var appModel: RemoteAppModel?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = 0
    private var visible = false
    private var active = true
    private var retries = 0

    func open(appModel: RemoteAppModel) {
        self.appModel = appModel; visible = true
        restart()
    }

    func connectionChanged() { restart() }
    func sceneChanged(_ phase: ScenePhase) {
        active = phase == .active
        if active { restart() } else { suspend() }
    }
    func selectDisplay(_ id: UInt32) {
        guard id != displayID else { return }
        displayID = id; restart()
    }
    func retry() { retries = 0; restart() }

    private func suspend() {
        generation += 1; task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        if let transport {
            transport.cancel()
            let decoder = decoder
            transport.queue.async { decoder.stop() }
        }
        transport = nil; showingVideo = false; keyboardFocused = false
    }

    private func restart() {
        suspend()
        guard visible, active, let appModel else { return }
        guard appModel.connectionState.isConnected else { statusKey = "stateReconnecting"; return }
        guard appModel.realtimeInputLinkKind == .network else { statusKey = "desktopBluetooth"; return }
        guard appModel.supportsRemoteDesktop else { statusKey = "desktopNeedsUpdate"; return }
        let epoch = generation
        statusKey = "stateConnecting"
        task = Task { [weak self] in
            // End is ordered before a replacement begin on the control link.
            await appModel.endRemoteVideo()
            guard !Task.isCancelled else { return }
            do {
                let (offer, host) = try await appModel.beginRemoteVideo(displayID: self?.displayID)
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                self.displays = offer.displays; self.displayID = offer.displayID
                let decoder = RemoteVideoDecoder()
                self.decoder = decoder; self.metrics = RemoteVideoMetrics(); self.encodeMs = nil; self.sourceDropped = 0
                let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: offer.port)!, using: RemoteVideoTransport.parameters())
                let transport = RemoteVideoTransport(connection: connection, secret: offer.secret, isServer: false)
                self.transport = transport
                decoder.onFirstFrame = { [weak self] in
                    Task { @MainActor in
                        guard let self, epoch == self.generation else { return }
                        self.showingVideo = true; self.statusKey = "stateConnected"; self.retries = 0
                        self.watchdog?.cancel(); self.watchdog = nil
                    }
                }
                decoder.onMetrics = { [weak self] metrics in
                    Task { @MainActor in
                        guard let self, epoch == self.generation else { return }
                        self.metrics = metrics
                    }
                }
                decoder.onNeedsKeyFrame = { [weak transport] in
                    guard let data = try? JSONEncoder().encode(RemoteVideoFeedback(needsKeyFrame: true, congested: true)) else { return }
                    transport?.send(RemoteVideoPacket(frameType: .feedback, payload: data))
                }
                transport.onReady = { [weak transport] in transport?.send(RemoteVideoPacket(frameType: .hello)) }
                transport.onPacket = { [weak self, weak transport] packet in
                    switch packet.frameType {
                    case .keyFrame, .deltaFrame: decoder.receive(packet)
                    case .config: break
                    case .focus:
                        if let focused = try? JSONDecoder().decode(Bool.self, from: packet.payload) {
                            Task { @MainActor in
                                guard let self, epoch == self.generation else { return }
                                self.keyboardFocused = focused
                                self.onKeyboardFocus?(focused)
                            }
                        }
                    case .diagnostics:
                        if let stats = try? JSONDecoder().decode(RemoteVideoDiagnostics.self, from: packet.payload) {
                            Task { @MainActor in
                                guard let self, epoch == self.generation else { return }
                                self.encodeMs = stats.encodeMs
                                self.sourceDropped = stats.droppedFrames
                            }
                        }
                    default:
                        transport?.cancel()
                        Task { @MainActor in self?.failed(epoch: epoch) }
                    }
                }
                transport.onFailure = { [weak self] in Task { @MainActor in self?.failed(epoch: epoch) } }
                self.watchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    self?.failed(epoch: epoch)
                }
                transport.start()
            } catch {
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                self.statusKey = (error as? RemoteConnectionError)?.messageKey ?? "desktopUnavailable"
                // Permission failures need user action; transport loss retries.
                if let error = error as? RemoteConnectionError {
                    switch error {
                    case .network, .server(.remoteVideoUnavailable), .server(.commandTimeout): self.failed(epoch: epoch)
                    default: break
                    }
                }
            }
        }
    }

    private func failed(epoch: Int) {
        guard epoch == generation, visible, active else { return }
        suspend(); statusKey = "desktopUnavailable"
        retries += 1
        let retryEpoch = generation
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(5, self?.retries ?? 1)))
            guard !Task.isCancelled, let self, retryEpoch == self.generation else { return }
            self.restart()
        }
    }

    func close() {
        visible = false; suspend()
        if let appModel { Task { await appModel.endRemoteVideo() } }
    }
}
