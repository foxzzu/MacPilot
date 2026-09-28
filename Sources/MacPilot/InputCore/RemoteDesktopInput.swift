import ApplicationServices
import CoreGraphics
import Foundation
import MacPilotRemoteProtocol

extension RemoteInputCoordinator {
    func desktopClick(_ pointer: RemotePointerRequest, connectionID: UUID) -> Bool {
        guard isSessionArmed(connectionID), AXIsProcessTrusted(),
              pointer.x.isFinite, pointer.y.isFinite,
              (0...1).contains(pointer.x), (0...1).contains(pointer.y),
              CGDisplayIsActive(pointer.displayID) != 0 else { return false }
        let bounds = CGDisplayBounds(pointer.displayID)
        let point = CGPoint(x: bounds.minX + pointer.x * max(0, bounds.width - 1),
                            y: bounds.minY + pointer.y * max(0, bounds.height - 1))
        guard let source = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
        move.post(tap: .cghidEventTap); down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    func desktopKey(_ request: RemoteKeyRequest, connectionID: UUID) -> Bool {
        guard isSessionArmed(connectionID), AXIsProcessTrusted(), request.modifiers <= 7,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let code: CGKeyCode
        switch request.key {
        case .escape: code = 53
        case .tab: code = 48
        case .delete: code = 51
        case .enter: code = 36
        case .character:
            let codes: [String: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
                "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
                "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
                "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
                "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
            guard let character = request.character, character.count == 1,
                  let value = codes[character.lowercased()] else { return false }
            code = value
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        var flags: CGEventFlags = []
        if request.modifiers & 1 != 0 { flags.insert(.maskControl) }
        if request.modifiers & 2 != 0 { flags.insert(.maskAlternate) }
        if request.modifiers & 4 != 0 { flags.insert(.maskCommand) }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}
