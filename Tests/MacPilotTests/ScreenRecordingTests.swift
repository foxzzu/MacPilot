import Foundation
import Carbon.HIToolbox
import AppKit
import AVFoundation
import QuartzCore
import Testing
@testable import MacPilot

struct ScreenRecordingTests {
    @Test @MainActor func recordingCallbacksKeepAppKitScreenCoordinates() throws {
        let capture = ScreenCaptureModel()
        let controller = capture.testMakeSmartCaptureController()
        defer { controller.stop() }
        var forwardedRect: CGRect?
        var expectedMode: ScreenRecordingCaptureMode = .area
        capture.onRecordingSelection = { rect, mode in
            #expect(mode == expectedMode)
            forwardedRect = rect
        }
        capture.onRecordingSelectionAction = { rect, mode, action in
            #expect(mode == expectedMode)
            #expect(action == .recordingStart)
            forwardedRect = rect
        }
        for mode in [SmartCaptureSelectionMode.recordingArea, .recordingApplication] {
            expectedMode = mode == .recordingApplication ? .application : .area
            for rect in [CGRect(x: 100, y: 40, width: 300, height: 180), CGRect(x: 100, y: 400, width: 300, height: 180)] {
                for action in [nil, AreaSelectionAction.recordingStart] {
                    forwardedRect = nil
                    controller.testDeliverRecordingSelection(rect: rect, mode: mode, action: action)
                    #expect(forwardedRect == rect)
                }
            }
        }
    }

    @Test @MainActor func startingFromTheSelectionBarKeepsAppKitScreenCoordinates() async throws {
        // Real selection windows and ScreenCaptureKit streams are isolated
        // acceptance checks, not part of the concurrent unit-test run.
        guard ProcessInfo.processInfo.environment["MACPILOT_VERIFY_RECORDING_PIXELS"] == "1" else { return }
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for screen in NSScreen.screens {
            let capture = ScreenCaptureModel()
            defer { capture.stop() }
            capture.recordingSelectionConfiguration = {
                RecordingSelectionBarConfiguration(language: .english, capturesMicrophone: false,
                    capturesSystemAudio: false, videoQuality: .high, cameraEnabled: false)
            }
            var recordingRect: CGRect?
            capture.onRecordingSelectionAction = { rect, mode, action in
                #expect(mode == .area)
                #expect(action == .recordingStart)
                recordingRect = rect
            }
            capture.startRecordingSelection(mode: .area)
            let controller = SnapzyAreaSelectionController.shared
            let window = try #require(controller.testWindows.first(where: { $0.displayID == screen.displayID }))
            for panel in controller.testWindows { panel.orderOut(nil) }
            let selectedRect = CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 340, width: 300, height: 180)
            controller.areaSelectionWindow(window, didSelectRect: selectedRect)
            controller.areaSelectionWindow(window, didRequestAction: .recordingStart)
            let forwardedRect = try #require(recordingRect)
            #expect(forwardedRect == selectedRect)
            let settings = ScreenRecordingSettings(outputFolder: folder.path, captureMode: .area)
            try await verifyRecordingPixels(settings: settings, captureRect: forwardedRect, selectedRect: selectedRect)
        }
    }

    /// Opt-in live acceptance: a solid fixture must fill the actual recorded
    /// frame on each display. Kept out of the concurrent suite because other
    /// capture tests deliberately put full-screen overlays above this fixture.
    @MainActor private func verifyRecordingPixels(settings: ScreenRecordingSettings, captureRect: CGRect, selectedRect: CGRect) async throws {
        let marker = NSPanel(contentRect: selectedRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        marker.title = "Camera Overlayer"
        marker.backgroundColor = .magenta
        marker.isOpaque = true
        marker.hasShadow = false
        marker.level = .screenSaver
        marker.ignoresMouseEvents = true
        marker.isReleasedWhenClosed = false
        marker.hidesOnDeactivate = false
        marker.sharingType = .readOnly
        marker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: CGRect(origin: .zero, size: selectedRect.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(red: 1, green: 0, blue: 1, alpha: 1)
        marker.contentView = view
        marker.orderFrontRegardless()
        defer { marker.close() }
        marker.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(marker.frame == selectedRect)
        // Make the fixture visible before the filter snapshots own-window
        // exclusions, just like the real capturable camera overlay.
        let session = try await ScreenRecordingEngine.makeSession(settings: settings, captureRect: captureRect)
        defer { session.cancelImmediately() }
        #expect(session.capturedScreenRect == selectedRect)
        try await session.start()
        try await Task.sleep(for: .milliseconds(150))
        // Force fresh frames after stream startup; the first buffer can
        // precede WindowServer's presentation of the newly shown fixture.
        view.layer?.backgroundColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(100))
        view.layer?.backgroundColor = CGColor(red: 1, green: 0, blue: 1, alpha: 1)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(300))
        let videoURL = try await session.stop()
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: CMTimeMultiplyByFloat64(duration, multiplier: 0.8)).image
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let correctPixelCount = try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 32, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] > 180 && bytes[$0 + 1] < 80 && bytes[$0 + 2] > 180
            }.count
        }
        #expect(correctPixelCount == 64, "Recorded pixels must match the fixture at \(selectedRect)")
    }

    @Test @MainActor func recordingPrepareBarUsesTheSameAppKitRegion() {
        for screen in NSScreen.screens {
            let rect = CGRect(x: screen.frame.minX + 100, y: screen.frame.maxY - 340, width: 300, height: 180)
            let barSize = CGSize(width: 200, height: 52)
            let origin = ScreenRecordingPrepareBarController.barOrigin(for: rect, barSize: barSize)
            #expect(origin.y == rect.minY - barSize.height - 12)
        }
    }

    @Test func recordingShortcutDefaultIsUsableAndMigratesTheOldSystemConflict() throws {
        #expect(ScreenRecordingSettings.defaultShortcut.displayName == "⌥⌘5")
        #expect(SmartCaptureSystemShortcutDetector.conflicts(for: ScreenRecordingSettings.defaultShortcut).isEmpty)

        let explicitLegacyBinding = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_ANSI_5),
            modifiers: [.command, .shift]
        )
        #expect(ScreenRecordingSettings(shortcut: explicitLegacyBinding).shortcut == explicitLegacyBinding)

        let legacy = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data("{\"shortcut\":{\"keyCode\":23,\"modifiers\":9}}".utf8)
        )
        #expect(legacy.shortcut == ScreenRecordingSettings.defaultShortcut)
    }

    @Test func recordingCaptureModesHaveStableLabelsAndRoundTrip() throws {
        #expect(ScreenRecordingCaptureMode.allCases == [.area, .fullscreen, .application, .audio])
        #expect(ScreenRecordingCaptureMode.area.titleKey == "scRecordingArea")
        #expect(ScreenRecordingCaptureMode.fullscreen.titleKey == "scRecordingFullscreen")
        #expect(ScreenRecordingCaptureMode.application.titleKey == "scRecordingApplication")
        #expect(ScreenRecordingCaptureMode.audio.titleKey == "scRecordingAudioMode")

        let settings = ScreenRecordingSettings(captureMode: .application)
        let decoded = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.captureMode == .application)
    }

    @Test @MainActor func areaRecordingRequestsASelectionBeforeStartingTheWriter() {
        let model = ScreenRecordingModel()
        model.setCaptureMode(.area)
        var requestedMode: ScreenRecordingCaptureMode?
        model.onRequestSelection = { requestedMode = $0 }

        model.start()

        #expect(requestedMode == .area)
        #expect(model.state == .idle)
    }

    @Test @MainActor func explicitCaptureModeStartBecomesTheDefaultAndRequestsThatRange() {
        let model = ScreenRecordingModel()
        model.setCaptureMode(.area)
        var requestedMode: ScreenRecordingCaptureMode?
        model.onRequestSelection = { requestedMode = $0 }

        model.start(captureMode: .application)

        #expect(model.settings.captureMode == .application)
        #expect(requestedMode == .application)
        #expect(model.state == .idle)
    }

    @Test func recordingSettingsClampFrameRateAndRoundTrip() throws {
        let settings = ScreenRecordingSettings(
            outputFolder: "/tmp/recordings",
            format: .mp4,
            framesPerSecond: 120,
            showsCursor: false,
            capturesSystemAudio: true
        )

        #expect(settings.framesPerSecond == 60)
        let decoded = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
    }

    @Test func recordingSettingsClampLowFrameRate() {
        #expect(ScreenRecordingSettings(framesPerSecond: 1).framesPerSecond == 5)
        #expect(ScreenRecordingSettings(framesPerSecond: 30).framesPerSecond == 30)
    }

    @Test func recordingSettingsDecodeLegacyPayloadWithSafeDefaults() throws {
        let settings = try JSONDecoder().decode(
            ScreenRecordingSettings.self,
            from: Data("{\"format\":\"mov\",\"framesPerSecond\":30}".utf8)
        )
        #expect(settings.captureMode == .area)
        #expect(settings.showsCursor)
        #expect(!settings.capturesSystemAudio)
    }

    @Test @MainActor func recordingModelPersistsPreferenceChanges() {
        let model = ScreenRecordingModel()
        var persisted = false
        model.persist = { persisted = true }

        model.setFormat(.mp4)
        model.setFramesPerSecond(24)
        model.setShowsCursor(false)
        model.setCapturesSystemAudio(true)

        #expect(model.settings.format == .mp4)
        #expect(model.settings.framesPerSecond == 24)
        #expect(!model.settings.showsCursor)
        #expect(model.settings.capturesSystemAudio)
        #expect(persisted)
    }

    @Test @MainActor func recordingShortcutRejectsScreenshotShortcutOutsideTheEditor() {
        let model = ScreenRecordingModel()
        let original = model.settings.shortcut
        let screenshotBinding = SmartCaptureShortcutBinding(
            keyCode: UInt16(kVK_ANSI_R),
            modifiers: [.command, .option]
        )
        model.isShortcutInUse = { $0 == screenshotBinding }

        #expect(!model.setShortcut(screenshotBinding))
        #expect(model.settings.shortcut == original)
    }

    @Test func recordingErrorsExposeStableLocalizationKeys() {
        #expect(ScreenRecordingError.permissionRequired.messageKey == "scRecordingPermissionRequired")
        #expect(ScreenRecordingError.noVideoFrames.messageKey == "scRecordingNoVideoFrames")
    }
}
