#if DEBUG || LAMITYPE_CAPTURE_CI
import AVFoundation
import Foundation
import os

/// Opt-in acoustic CI artifact. The snapshot is the same mono PCM returned to dictation.
enum CaptureDump {
    private static let writer = DispatchQueue(label: "com.felix.hushtype.capture-dump", qos: .utility)

    static func enqueue(_ samples: [Float], pressUptimeMs: Int64?, outcome: String) {
        guard let path = ProcessInfo.processInfo.environment["LAMITYPE_CAPTURE_DUMP_DIR"],
              path.hasPrefix("/") else { return }
        let parent = URL(fileURLWithPath: path, isDirectory: true)
        let id = "capture-\(pressUptimeMs.map(String.init) ?? "unknown")-\(outcome)-\(UUID().uuidString)"
        writer.async {
            do {
                try write(samples, in: parent, id: id)
            } catch {
                Logger(subsystem: "com.felix.hushtype", category: "audio").error("Capture dump write failed")
            }
        }
    }

    static func write(_ samples: [Float], in parent: URL, id: String) throws {
        let fm = FileManager.default
        let staging = parent.appendingPathComponent(".\(id).partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        // Float WAV preserves hot-mic excursions and small signals exactly.
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let url = staging.appendingPathComponent("samples.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            if !samples.isEmpty {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                try file.write(from: buffer)
            }
        }

        var csv = "start_sample,sample_count,rms\n"
        for start in stride(from: 0, to: samples.count, by: 1600) {
            let block = samples[start..<min(start + 1600, samples.count)]
            let squares = block.reduce(0.0) { $0 + Double($1) * Double($1) }
            csv += "\(start),\(block.count),\(sqrt(squares / Double(block.count)))\n"
        }
        try Data(csv.utf8).write(to: staging.appendingPathComponent("rms.csv"))
        try fm.moveItem(at: staging, to: parent.appendingPathComponent(id, isDirectory: true))
    }
}
#endif
