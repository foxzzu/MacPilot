import AVFoundation
import UIKit

/// The physical trackpad click, synthesized at runtime.
///
/// iPads have no Taptic engine, so where an iPhone would buzz the iPad plays
/// this short "tap" instead — a damped low thump with a tiny high tick, the
/// sound a MacBook trackpad's click makes. Nothing is bundled: the 28 ms WAV
/// is generated once from a couple of decaying sinusoids and cached in an
/// `AVAudioPlayer`.
@MainActor
enum TrackpadClickSound {
    private static var player: AVAudioPlayer?

    static func play(deep: Bool = false) {
        if player == nil {
            player = makePlayer(deep: deep)
        }
        guard let player else { return }
        player.volume = deep ? 0.55 : 0.4
        player.rate = deep ? 1.0 : 1.15
        player.currentTime = 0
        player.enableRate = true
        player.play()
    }

    private static func makePlayer(deep: Bool) -> AVAudioPlayer? {
        // Ambient mixes with whatever is playing and respects the mute
        // switch: click feedback must never interrupt the user's audio.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let data = clickWavData() else { return nil }
        let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        player?.enableRate = true
        player?.volume = deep ? 0.55 : 0.4
        player?.prepareToPlay()
        return player
    }

    /// 48 kHz mono 16-bit PCM, ~30 ms.
    private static func clickWavData() -> Data? {
        let sampleRate = 48_000
        let duration = 0.03
        let sampleCount = Int(Double(sampleRate) * duration)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            // The body of the click: a fast-decaying low thump…
            let thump = sin(2 * .pi * 190 * t) * exp(-t * 160)
            // …plus the sharp attack the mechanism's snap makes.
            let tick = sin(2 * .pi * 2_300 * t) * exp(-t * 900) * 0.3
            let value = (thump * 0.85 + tick) * 0.6
            var frame = Int16(clamping: Int(value * Double(Int16.max)))
            withUnsafeBytes(of: &frame) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        func ascii(_ string: String) { wav.append(string.data(using: .ascii)!) }
        func le32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        let dataLength = UInt32(pcm.count)
        ascii("RIFF")
        le32(36 + dataLength)
        ascii("WAVE")
        ascii("fmt ")
        le32(16)
        le16(1) // PCM
        le16(1) // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2)) // byte rate
        le16(2) // block align
        le16(16) // bits per sample
        ascii("data")
        le32(dataLength)
        wav.append(pcm)
        return wav
    }
}
