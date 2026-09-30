import Foundation
import IOKit.pwr_mgt
import OSLog

struct AwakeAssertionFailure: Error, Equatable, LocalizedError, Sendable {
    enum Kind: String, Sendable {
        case systemSleep
        case displaySleep
    }

    let kind: Kind
    let operation: String
    let code: String

    var errorDescription: String? {
        operation + " (" + kind.rawValue + ", code " + code + ")"
    }
}

@MainActor
protocol AwakeAssertionControlling: AnyObject {
    var isSystemAssertionActive: Bool { get }
    var isDisplayAssertionActive: Bool { get }

    @discardableResult
    func apply(_ desiredState: DesiredAwakeState) -> Result<Void, AwakeAssertionFailure>

    @discardableResult
    func releaseAll() -> Result<Void, AwakeAssertionFailure>
}

enum AwakeAssertionHealth: Equatable {
    case active
    case missing
    case failed(IOReturn)
}

/// The IOKit boundary is injectable so recovery tests never change host power policy.
@MainActor
protocol AwakePowerAssertionAPI {
    func create(type: String, reason: String) -> (code: IOReturn, id: IOPMAssertionID)
    func ensureActive(_ id: IOPMAssertionID) -> AwakeAssertionHealth
    func release(_ id: IOPMAssertionID) -> IOReturn
}

struct IOKitAwakePowerAssertionAPI: AwakePowerAssertionAPI {
    private let copyProperties: (IOPMAssertionID) -> NSDictionary?
    private let setLevelOn: (IOPMAssertionID) -> IOReturn

    init(
        copyProperties: @escaping (IOPMAssertionID) -> NSDictionary? = {
            IOPMAssertionCopyProperties($0)?.takeRetainedValue() as NSDictionary?
        },
        setLevelOn: @escaping (IOPMAssertionID) -> IOReturn = {
            IOPMAssertionSetProperty($0, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn))
        }
    ) {
        self.copyProperties = copyProperties
        self.setLevelOn = setLevelOn
    }

    func create(type: String, reason: String) -> (code: IOReturn, id: IOPMAssertionID) {
        var id = IOPMAssertionID()
        let code = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
        )
        return (code, id)
    }

    func ensureActive(_ id: IOPMAssertionID) -> AwakeAssertionHealth {
        if let properties = copyProperties(id) {
            guard let level = properties[kIOPMAssertionLevelKey] as? NSNumber else {
                return .failed(kIOReturnError)
            }
            if level.uint32Value == kIOPMAssertionLevelOn { return .active }
        }
        // CopyProperties returns nil for both a missing ID and a query failure.
        // With these fixed valid level arguments, powerd's lookupAssertion
        // returns BadArgument for an absent ID (observed on macOS 26), while
        // the public contract specifies NotFound. Transport/permission failures
        // retain the ID so a transient outage cannot duplicate it.
        // https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMAssertions.c
        let code = setLevelOn(id)
        switch code {
        case kIOReturnSuccess: return .active
        case kIOReturnNotFound, kIOReturnBadArgument: return .missing
        default: return .failed(code)
        }
    }

    func release(_ id: IOPMAssertionID) -> IOReturn {
        IOPMAssertionRelease(id)
    }
}

/// Owns the process' two ordinary IOKit power assertions.
///
/// The controller deliberately knows nothing about sessions. It only moves
/// the current system state toward the desired aggregate state and keeps the
/// assertion IDs stable across repeated applications.
@MainActor
final class AwakeAssertionController: AwakeAssertionControlling {
    private let logger = Logger(subsystem: "com.misswell.macpilot", category: "Awake.Assertion")
    private let reason = "MacPilot Awake"
    private let api: any AwakePowerAssertionAPI
    private var systemAssertionID: IOPMAssertionID?
    private var displayAssertionID: IOPMAssertionID?

    private(set) var isSystemAssertionActive = false
    private(set) var isDisplayAssertionActive = false

    init(api: any AwakePowerAssertionAPI = IOKitAwakePowerAssertionAPI()) {
        self.api = api
    }

    @discardableResult
    func apply(_ desiredState: DesiredAwakeState) -> Result<Void, AwakeAssertionFailure> {
        let systemFailure = updateSystemAssertion(enabled: desiredState.preventSystemSleep)
        let displayFailure = updateDisplayAssertion(enabled: desiredState.preventDisplaySleep)
        let firstFailure = systemFailure ?? displayFailure
        isSystemAssertionActive = systemAssertionID != nil && systemFailure == nil
        isDisplayAssertionActive = displayAssertionID != nil && displayFailure == nil
        if let firstFailure { return .failure(firstFailure) }
        return .success(())
    }

    @discardableResult
    func releaseAll() -> Result<Void, AwakeAssertionFailure> {
        apply(.inactive)
    }

    private func failure(kind: AwakeAssertionFailure.Kind, operation: String, code: IOReturn) -> AwakeAssertionFailure {
        let failure = AwakeAssertionFailure(kind: kind, operation: operation, code: String(describing: code))
        logger.error("\(failure.localizedDescription, privacy: .public)")
        return failure
    }

    private func updateSystemAssertion(enabled: Bool) -> AwakeAssertionFailure? {
        updateAssertion(
            enabled: enabled,
            currentID: systemAssertionID,
            kind: .systemSleep,
            assertionType: kIOPMAssertionTypePreventUserIdleSystemSleep
        ) { [weak self] id in
            self?.systemAssertionID = id
        }
    }

    private func updateDisplayAssertion(enabled: Bool) -> AwakeAssertionFailure? {
        updateAssertion(
            enabled: enabled,
            currentID: displayAssertionID,
            kind: .displaySleep,
            assertionType: kIOPMAssertionTypePreventUserIdleDisplaySleep
        ) { [weak self] id in
            self?.displayAssertionID = id
        }
    }

    private func updateAssertion(
        enabled: Bool,
        currentID: IOPMAssertionID?,
        kind: AwakeAssertionFailure.Kind,
        assertionType: String,
        setID: (IOPMAssertionID?) -> Void
    ) -> AwakeAssertionFailure? {
        if enabled {
            if let currentID {
                switch api.ensureActive(currentID) {
                case .active: return nil
                case .missing:
                    setID(nil)
                    logger.notice("Recovering missing \(kind.rawValue, privacy: .public) assertion")
                case .failed(let code):
                    return failure(kind: kind, operation: "Assertion health check failed", code: code)
                }
            }

            let (result, assertionID) = api.create(type: assertionType, reason: reason)
            guard result == kIOReturnSuccess else {
                let failure = AwakeAssertionFailure(
                    kind: kind,
                    operation: "IOPMAssertionCreateWithName failed",
                    code: String(describing: result)
                )
                logger.error("\(failure.localizedDescription, privacy: .public)")
                return failure
            }
            setID(assertionID)
            logger.notice("Created \(kind.rawValue, privacy: .public) assertion")
            return nil
        }

        guard let currentID else { return nil }
        let result = api.release(currentID)
        // Release has no variable arguments except our previously created ID;
        // BadArgument is powerd's absent-ID result, just as in ensureActive.
        guard result == kIOReturnSuccess || result == kIOReturnNotFound || result == kIOReturnBadArgument else {
            let failure = AwakeAssertionFailure(
                kind: kind,
                operation: "IOPMAssertionRelease failed",
                code: String(describing: result)
            )
            logger.error("\(failure.localizedDescription, privacy: .public)")
            return failure
        }
        setID(nil)
        logger.notice("Released \(kind.rawValue, privacy: .public) assertion")
        return nil
    }
}
