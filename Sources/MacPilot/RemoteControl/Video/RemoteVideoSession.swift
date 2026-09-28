import AppKit
import CoreGraphics
import Foundation
import MacPilotRemoteProtocol
import MacPilotRemoteTransport
import Network
@preconcurrency import ScreenCaptureKit

/// Owned by one authenticated control connection. Revocation, disconnection
/// and endRemoteVideo destroy the listener, socket and capture together.
@MainActor
final class RemoteVideoSession {
    private var listener: NWListener?
    private var transport: RemoteVideoTransport?
    private var capture: RemoteScreenCapture?
    private var focusMonitor: RemoteKeyboardFocusMonitor?
    private var closed = false
    private var authenticated = false
    private var deadline: Task<Void, Never>?
    private var portWaiter: CheckedContinuation<UInt16, Error>?
    private var captureTask: Task<Void, Never>?
    private let secret = RemoteCrypto.randomData(count: 32)
    private(set) var displayID: UInt32 = 0

    func prepare(displayID requestedID: UInt32?) async throws -> RemoteVideoOffer {
        guard CGPreflightScreenCaptureAccess() else {
            // Explicit user initiation may bring up the macOS permission UI.
            _ = CGRequestScreenCaptureAccess()
            throw RemoteVideoFailure.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !closed, let display = content.displays.first(where: { $0.displayID == (requestedID ?? CGMainDisplayID()) })
                ?? (requestedID == nil ? content.displays.first : nil) else { throw RemoteVideoFailure.capture }
        self.displayID = display.displayID
        let displays = content.displays.map { display in
            RemoteDisplayInfo(id: display.displayID,
                name: NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID })?.localizedName ?? "Display \(display.displayID)",
                width: display.width, height: display.height)
        }
        let listener = try NWListener(using: RemoteVideoTransport.parameters(), on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, display: display) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            portWaiter = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let waiter = self.portWaiter else { return }
                    switch state {
                    case .ready:
                        self.portWaiter = nil
                        if let port = listener?.port { waiter.resume(returning: port.rawValue) }
                        else { waiter.resume(throwing: RemoteVideoFailure.transport) }
                    case .failed, .cancelled:
                        self.portWaiter = nil; waiter.resume(throwing: RemoteVideoFailure.transport)
                    default: break
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "com.misswell.macpilot.video.listener", qos: .utility))
        }
        guard !closed else { throw RemoteVideoFailure.transport }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.authenticated else { return }
            self.stop()
        }
        return RemoteVideoOffer(port: port, secret: secret, displays: displays, displayID: display.displayID)
    }

    private func accept(_ connection: NWConnection, display: SCDisplay) {
        guard !closed, transport == nil else { connection.cancel(); return }
        let transport = RemoteVideoTransport(connection: connection, secret: secret, isServer: true)
        self.transport = transport
        let capture = RemoteScreenCapture(transport: transport)
        self.capture = capture
        capture.onFailure = { [weak self] in Task { @MainActor in self?.stop() } }
        transport.onSendCompleted = { [weak capture] milliseconds in capture?.sentIn(milliseconds: milliseconds) }
        transport.onPacket = { [weak self] packet in
            Task { @MainActor in self?.handle(packet, display: display) }
        }
        transport.onFailure = { [weak self] in Task { @MainActor in self?.stop() } }
        transport.start()
    }

    private func handle(_ packet: RemoteVideoPacket, display: SCDisplay) {
        guard !closed, let transport else { return }
        if !authenticated {
            guard packet.frameType == .hello, packet.payload.isEmpty else { stop(); return }
            authenticated = true; deadline?.cancel(); deadline = nil
            listener?.cancel(); listener = nil
            let info = RemoteDisplayInfo(id: display.displayID, name: "", width: display.width, height: display.height)
            guard let payload = try? JSONEncoder().encode(info), transport.send(RemoteVideoPacket(frameType: .config, payload: payload)) else { stop(); return }
            guard let capture else { stop(); return }
            let monitor = RemoteKeyboardFocusMonitor(transport: transport)
            focusMonitor = monitor
            monitor.start()
            captureTask = Task { [weak self] in
                do {
                    try await capture.start(display: display)
                    if Task.isCancelled || self?.closed != false { capture.stop() }
                } catch { self?.stop() }
            }
        } else if packet.frameType == .feedback,
                  let feedback = try? JSONDecoder().decode(RemoteVideoFeedback.self, from: packet.payload) {
            capture?.feedback(feedback)
        } else { stop() }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        portWaiter?.resume(throwing: RemoteVideoFailure.transport); portWaiter = nil
        deadline?.cancel(); deadline = nil
        captureTask?.cancel(); captureTask = nil
        listener?.cancel(); listener = nil
        transport?.cancel(); transport = nil
        focusMonitor?.stop(); focusMonitor = nil
        capture?.stop(); capture = nil
    }
}
