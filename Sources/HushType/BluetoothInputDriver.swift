import AVFoundation
import CoreAudio

/// Dictation can read native 16 kHz samples directly from a Bluetooth microphone
/// while playback is routed to the built-in speakers. Other output routes
/// may use the same headset even when HAL lists separate input and output IDs.
final class BluetoothInputDriver: CaptureDriver {
    private struct Route: Equatable {
        let device: AudioObjectID
        let stream: AudioObjectID
        let output: AudioObjectID

        static var defaultInput: AudioObjectID? {
            propertyID(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice))
        }

        static func current() -> Self? {
            guard let device = defaultInput,
                  device != kAudioObjectUnknown,
                  propertyID(device, address(kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBluetooth,
                  let output = propertyID(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice)),
                  output != kAudioObjectUnknown, output != device,
                  BluetoothInputDriver.supportsOutput(transport: propertyID(output, address(kAudioDevicePropertyTransportType))),
                  propertySize(device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) == 0
            else { return nil }

            let streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            guard propertySize(device, streams) == UInt32(MemoryLayout<AudioObjectID>.size),
                  let stream = propertyID(device, streams) else { return nil }
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: format))
            var key = address(kAudioStreamPropertyVirtualFormat)
            guard AudioObjectGetPropertyData(stream, &key, 0, nil, &size, &format) == noErr,
                  format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 16_000,
                  format.mChannelsPerFrame == 1, format.mBytesPerFrame == 4, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return nil }
            return Self(device: device, stream: stream, output: output)
        }

        private static func propertyID(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> UInt32? {
            var key = property
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            guard AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value) == noErr,
                  size == MemoryLayout<UInt32>.size else { return nil }
            return value
        }

        private static func propertySize(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> UInt32? {
            var key = property
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(object, &key, 0, nil, &size) == noErr ? size : nil
        }
    }

    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let route: Route
    private var ioProc: AudioDeviceIOProcID?
    private let notifications = DispatchQueue(label: "com.felix.hushtype.bluetooth-input-changes")
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Establish the HAL metadata connection off the press path. This reads a
    /// system property only. No device is opened and no route is retained.
    static func warmDeviceLookup() {
        DispatchQueue.global(qos: .utility).async {
            _ = Route.defaultInput
        }
    }

    static var defaultInputDevice: AudioObjectID? { Route.defaultInput }

    static func supportsOutput(transport: UInt32?) -> Bool {
        transport == kAudioDeviceTransportTypeBuiltIn
    }

    init?() {
        guard let route = Route.current() else { return nil }
        self.route = route
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onConfigurationChange: @escaping () -> Void) throws {
        let format = inputFormat
        let properties = [
            (AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultInputDevice)),
            (AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultOutputDevice)),
            (route.device, Self.address(kAudioDevicePropertyDeviceIsAlive)),
            (route.device, Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)),
            (route.stream, Self.address(kAudioStreamPropertyVirtualFormat)),
        ]
        do {
            for (object, var key) in properties {
                let listener: AudioObjectPropertyListenerBlock = { _, _ in onConfigurationChange() }
                try check(AudioObjectAddPropertyListenerBlock(object, &key, notifications, listener))
                listeners.append((object, key, listener))
            }
            // Catch a route change between the first metadata read and listener installation.
            guard Route.current() == route else { throw AudioCaptureError.configurationChanged }
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, route.device, nil) { _, input, _, _, _ in
                let buffer = input.pointee.mBuffers
                guard input.pointee.mNumberBuffers == 1, buffer.mNumberChannels == 1,
                      buffer.mData != nil, buffer.mDataByteSize >= 4, buffer.mDataByteSize.isMultiple(of: 4),
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                else { return }
                // The service copies the samples synchronously before this I/O cycle ends.
                pcm.frameLength = buffer.mDataByteSize / 4
                onBuffer(pcm)
            })
            guard let ioProc else { throw AudioCaptureError.invalidInput }
            try check(AudioDeviceStart(route.device, ioProc))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for (object, var key, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &key, notifications, listener)
        }
        listeners.removeAll()
        if let ioProc {
            AudioDeviceStop(route.device, ioProc)
            AudioDeviceDestroyIOProcID(route.device, ioProc)
            self.ioProc = nil
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
