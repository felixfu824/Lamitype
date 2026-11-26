#if DEBUG || LAMITYPE_CAPTURE_CI
import AVFoundation
import XCTest
@testable import HushType

final class CaptureDumpTests: XCTestCase {
    func testFloatWAVAndEnvelopeMatchReleasedSamplesIncludingPartialBlock() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        for samples in [[], Array(repeating: Float(-0.25), count: 1600) + [1.5, -1.5]] {
            let id = "capture-\(samples.count)"
            try CaptureDump.write(samples, in: parent, id: id)
            let folder = parent.appendingPathComponent(id)
            let file = try AVAudioFile(forReading: folder.appendingPathComponent("samples.wav"))
            XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            let csv = try String(contentsOf: folder.appendingPathComponent("rms.csv"), encoding: .utf8)
            if samples.isEmpty {
                XCTAssertEqual(csv, "start_sample,sample_count,rms\n")
            } else {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
                try file.read(into: buffer)
                XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), samples)
                XCTAssertEqual(csv, "start_sample,sample_count,rms\n0,1600,0.25\n1600,2,1.5\n")
            }
        }
    }
}
#endif
