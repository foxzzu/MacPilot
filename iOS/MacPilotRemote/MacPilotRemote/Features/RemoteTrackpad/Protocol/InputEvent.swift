import Foundation
import MacPilotRemoteProtocol

/// A pointer action ready to leave the trackpad module.
///
/// The engine and the motion pipeline speak this type; `InputEncoder` is the
/// only place it meets the wire format, which is what keeps the trackpad
/// ignorant of both the transport and the packet layout.
enum InputEvent: Equatable {
    case move(dx: Double, dy: Double, dragging: Bool)
    case click(button: RemoteInputButton, action: RemoteInputAction)
    /// A click graded by the pressure simulation. Only sent to Macs that
    /// advertise `.inputPressure`; everyone else gets plain clicks.
    case press(button: RemoteInputButton, action: RemoteInputAction, pressure: Double)
    /// The continuous press for Macs advertising `.inputPressureStream`.
    case pressBegin(button: RemoteInputButton, pressure: Double)
    case pressUpdate(pressure: Double)
    case pressEnd(button: RemoteInputButton)
    case scroll(dx: Double, dy: Double)
}

/// Turns engine output into the binary batch the connection layer sends.
enum InputEncoder {
    static func encode(_ events: [InputEvent]) -> RemoteInputBatch {
        RemoteInputBatch(
            timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            events: events.map { event in
                switch event {
                case let .move(dx, dy, dragging):
                    var buttons: RemoteInputButtons = []
                    if dragging { buttons.insert(.left) }
                    return .move(dx: dx, dy: dy, buttons: buttons)
                case let .click(button, action):
                    return .click(button: button, action: action)
                case let .press(button, action, pressure):
                    return .press(button: button, action: action, pressure: pressure)
                case let .pressBegin(button, pressure):
                    return .pressBegin(button: button, pressure: pressure)
                case let .pressUpdate(pressure):
                    return .pressUpdate(pressure: pressure)
                case let .pressEnd(button):
                    return .pressEnd(button: button)
                case let .scroll(dx, dy):
                    return .scroll(dx: dx, dy: dy)
                }
            }
        )
    }
}
