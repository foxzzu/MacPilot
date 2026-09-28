import CoreMedia
import CoreVideo
import Darwin
import Foundation
import MacPilotRemoteProtocol
import Testing
@testable import MacPilot

struct RemoteVideoEncoderTests {
    @Test(.timeLimit(.minutes(1)))
    func hardwareH264HasRecoverableKeyframesAndBoundedEncodeLatency() async throws {
        let harness = VideoEncoderHarness()
        let result = try await harness.run()
        #expect(result.packets.count == 30)
        let first = try #require(result.packets.first)
        #expect(first.frameType == .keyFrame)
        let frame = try RemoteH264Frame.decode(first.payload, keyFrame: true)
        #expect(!frame.sps.isEmpty && !frame.pps.isEmpty)
        #expect(result.packets.contains(where: { $0.frameType == .deltaFrame }))
        #expect(result.averageMs < 1000)
        print(String(format: "RemoteVideo synthetic 720p: encode avg=%.2fms max=%.2fms CPU=%.1f%% (one core); 30 frames, no capture/network/display", result.averageMs, result.maximumMs, result.cpuPercent))
    }
}

private struct VideoEncoderResult: Sendable {
    let packets: [RemoteVideoPacket]
    let averageMs: Double
    let maximumMs: Double
    let cpuPercent: Double
}

/// Harness state, including the VT session, belongs to queue. Only the
/// continuation and immutable result leave it.
private final class VideoEncoderHarness: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.misswell.macpilot.video.test")
    private let encoder = RemoteVideoEncoder()
    private var continuation: CheckedContinuation<VideoEncoderResult, Error>?
    private var packets: [RemoteVideoPacket] = []
    private var timings: [Double] = []
    private var started = 0.0
    private var cpuStarted = 0.0

    func run() async throws -> VideoEncoderResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                do {
                    try self.encoder.configure(width: 1280, height: 720, quality: .balanced)
                    self.started = ProcessInfo.processInfo.systemUptime
                    self.cpuStarted = Self.cpuSeconds()
                    self.next()
                } catch { self.finish(error: error) }
            }
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func next() {
        let index = packets.count
        if index == 30 {
            encoder.stop()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let result = VideoEncoderResult(packets: packets,
                averageMs: timings.reduce(0, +) / Double(timings.count), maximumMs: timings.max() ?? 0,
                cpuPercent: (Self.cpuSeconds() - cpuStarted) / elapsed * 100)
            continuation?.resume(returning: result); continuation = nil
            return
        }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else {
            finish(error: RemoteVideoFailure.encoder); return
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<2 {
            if let address = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) {
                memset(address, plane == 0 ? Int32(16 + index) : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        encoder.encode(pixel, time: CMTime(value: Int64(index), timescale: 30), forceKeyFrame: index == 0) { packet, ms in
            self.queue.async {
                guard let packet else { self.finish(error: RemoteVideoFailure.encoder); return }
                self.packets.append(packet); self.timings.append(ms)
                self.next()
            }
        }
    }

    private func finish(error: Error) {
        encoder.stop()
        continuation?.resume(throwing: error); continuation = nil
    }
}
