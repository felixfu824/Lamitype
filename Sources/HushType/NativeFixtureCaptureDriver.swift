#if DEBUG
import AppKit
import AVFoundation
import AudioCommon

/// Opt-in test input only. Ordinary debug launches and every release build use
/// AVEngineCaptureDriver. No OS device or microphone setting is changed.
@MainActor
enum NativeFixtureAudioInput {
    static var nextURL: URL?
    static var isEnabled: Bool {
        ["com.felix.hushtype", "com.felix.lamitype.localLiveQA"].contains(Bundle.main.bundleIdentifier ?? "")
            && CommandLine.arguments.contains("--native-e2e")
            && CommandLine.arguments.contains("--qa-fixture-input")
    }
}

/// Streams a WAV at wall-clock pace through the existing capture-driver seam.
/// 48 kHz input also exercises AudioCaptureService's production conversion to
/// 16 kHz mono. This validates downstream behavior, not physical mic capture.
final class NativeFixtureCaptureDriver: CaptureDriver {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let url: URL?
    private var timer: DispatchSourceTimer?

    init(url: URL?) { self.url = url }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onConfigurationChange: @escaping () -> Void) throws {
        guard let url else { throw LiveRecognitionError.unavailable }
        let samples = try AudioFileLoader.load(url: url, targetSampleRate: 48_000)
        guard !samples.isEmpty else { throw LiveRecognitionError.empty }
        let format = inputFormat
        let queue = DispatchQueue(label: "com.felix.hushtype.native-fixture", qos: .userInitiated)
        let source = DispatchSource.makeTimerSource(queue: queue)
        let started = ProcessInfo.processInfo.systemUptime
        var offset = 0
        source.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
        source.setEventHandler {
            // Catch up monotonically after scheduling delays; never drop or
            // repeat fixture samples. Pad EOF with silence until capture stops.
            let due = Int((ProcessInfo.processInfo.systemUptime - started) * 48_000)
            while offset < due {
                let count = min(4096, due - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
                buffer.frameLength = AVAudioFrameCount(count)
                guard let data = buffer.floatChannelData?[0] else { return }
                for index in 0..<count { data[index] = offset + index < samples.count ? samples[offset + index] : 0 }
                offset += count
                onBuffer(buffer)
            }
        }
        timer = source
        source.resume()
    }

    func stop() { timer?.cancel(); timer = nil }
}
#endif
