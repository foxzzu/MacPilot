import Foundation
import Testing
@testable import MacPilotUpdaterSupport

struct UpdaterLaunchPlanTests {
    @Test func relaunchPlanRunsTheReplacedBundleExecutable() {
        let application = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            UpdaterLaunchPlan.directExecutableURL(for: application).path
                == "/Applications/MacPilot.app/Contents/MacOS/MacPilot"
        )
        #expect(
            UpdaterLaunchPlan.directExecutableURL(
                for: URL(fileURLWithPath: "/Applications/OctoPilot.app"),
                executableName: "OctoPilot"
            ).path == "/Applications/OctoPilot.app/Contents/MacOS/OctoPilot"
        )
    }
}

struct FinderSyncRegistrationTests {
    @Test func enabledExtensionIsPausedBeforeReplacementAndResumedAfterRegistration() throws {
        var events: [String] = []
        try FinderSyncRegistration.withSuspendedElection(
            wasEnabled: true,
            execute: { events.append($0.joined(separator: " ")) },
            operation: {
                events.append("replace bundle")
                events.append("refresh registration")
            }
        )
        #expect(events == [
            "-e ignore -i com.misswell.macpilot.finder-sync",
            "replace bundle",
            "refresh registration",
            "-e use -i com.misswell.macpilot.finder-sync"
        ])
    }

    @Test func failedReplacementRestoresElectionAndPreservesTheOriginalError() {
        enum Failure: Error { case replacement }
        var events: [String] = []
        do {
            try FinderSyncRegistration.withSuspendedElection(
                wasEnabled: true,
                execute: { events.append($0.joined(separator: " ")) },
                operation: { throw Failure.replacement }
            )
            Issue.record("Replacement failure must propagate")
        } catch {
            #expect(error is Failure)
        }
        #expect(events == [
            "-e ignore -i com.misswell.macpilot.finder-sync",
            "-e use -i com.misswell.macpilot.finder-sync"
        ])
    }

    @Test func disabledElectionIsLeftDisabledThroughoutReplacement() throws {
        var replaced = false
        try FinderSyncRegistration.withSuspendedElection(
            wasEnabled: false,
            execute: { _ in Issue.record("A disabled extension must not be elected") },
            operation: { replaced = true }
        )
        #expect(replaced)
    }

    @Test func failedSuspensionPreventsBundleReplacement() {
        enum Failure: Error { case suspension }
        var replaced = false
        #expect(throws: Failure.self) {
            try FinderSyncRegistration.withSuspendedElection(
                wasEnabled: true,
                execute: { _ in throw Failure.suspension },
                operation: { replaced = true }
            )
        }
        #expect(!replaced)
    }

    @Test func restorationFailureIsReportedWithoutMaskingReplacementFailure() {
        enum Failure: Error, Equatable { case replacement, restoration }
        var reported: Failure?
        do {
            try FinderSyncRegistration.withSuspendedElection(
                wasEnabled: true,
                execute: { if $0.contains("use") { throw Failure.restoration } },
                restorationFailed: { reported = $0 as? Failure },
                operation: { throw Failure.replacement }
            )
            Issue.record("Replacement failure must propagate")
        } catch {
            #expect((error as? Failure) == .replacement)
        }
        #expect(reported == .restoration)
    }

    @Test func startupRecoveryDoesNotOverrideADisabledSystemExtension() throws {
        var commands: [[String]] = []
        let recovered = try FinderSyncRegistration.recoverIfEnabled(
            at: URL(fileURLWithPath: "/Applications/MacPilot.app"),
            execute: {
                commands.append($0)
                return "-    com.misswell.macpilot.finder-sync(1.1.501)"
            }
        )
        #expect(!recovered)
        #expect(commands == [FinderSyncRegistration.queryArguments()])
    }

    @Test func startupRecoveryRemovesStaleVersionsWhileLaunchesAreSuspended() throws {
        let app = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let current = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
        let stale = "/Users/developer/Code/MacPilot.app/Contents/PlugIns/FinderSync.appex"
        var commands: [[String]] = []
        let recovered = try FinderSyncRegistration.recoverIfEnabled(at: app, execute: {
            commands.append($0)
            if $0 == FinderSyncRegistration.queryArguments() {
                return "+    com.misswell.macpilot.finder-sync(1.1.501)"
            }
            if $0 == FinderSyncRegistration.queryArguments(includeAllVersions: true) {
                return """
                + com.misswell.macpilot.finder-sync(1.1.469)\tOLD\t\(stale)
                + com.misswell.macpilot.finder-sync(1.1.501)\tNEW\t\(current)
                """
            }
            return ""
        })
        #expect(recovered)
        #expect(commands == [
            FinderSyncRegistration.queryArguments(),
            FinderSyncRegistration.queryArguments(includeAllVersions: true),
            ["-e", "ignore", "-i", FinderSyncRegistration.extensionBundleIdentifier],
            ["-r", stale], ["-r", current], ["-a", current],
            ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]
        ])
    }

    @Test func refreshRemovesTheExistingExtensionBeforeAddingTheReplacement() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")
        let extensionPath = "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                registeredExtensionPaths: [extensionPath],
                restoreEnabledElection: true
            ) == [
                ["-r", extensionPath],
                ["-a", extensionPath],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]
            ]
        )
    }

    @Test func enabledExtensionRestoresUseElectionAfterReplacement() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                restoreEnabledElection: true
            ) == [
                ["-r", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"],
                ["-a", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"],
                ["-e", "use", "-i", FinderSyncRegistration.extensionBundleIdentifier]
            ]
        )
    }

    @Test func disabledExtensionIsNotSilentlyReenabled() {
        let appURL = URL(fileURLWithPath: "/Applications/MacPilot.app")

        #expect(
            FinderSyncRegistration.registrationArguments(
                for: appURL,
                restoreEnabledElection: false
            ) == [
                ["-r", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"],
                ["-a", "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"]
            ]
        )
    }

    @Test func onlyEnabledMatchingExtensionIsRestored() {
        #expect(
            FinderSyncRegistration.isElectedForUse(
                in: "     com.apple.FinderSync(1.0)\n+    com.misswell.macpilot.finder-sync(1.1.263)"
            )
        )
        #expect(
            !FinderSyncRegistration.isElectedForUse(
                in: "     com.misswell.macpilot.finder-sync(1.1.263)"
            )
        )
    }

    @Test func registeredPathsExtractAllDuplicateExtensionRecords() {
        let output = """
        +    com.misswell.macpilot.finder-sync(1.1.278)\tOLD-UUID\t/Applications/OctoPilot.app/Contents/PlugIns/FinderSync.appex
             com.misswell.macpilot.finder-sync(1.1.279)\tNEW-UUID\t/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex
        """

        #expect(
            FinderSyncRegistration.registeredExtensionPaths(in: output) == [
                "/Applications/OctoPilot.app/Contents/PlugIns/FinderSync.appex",
                "/Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex"
            ]
        )
    }
}
