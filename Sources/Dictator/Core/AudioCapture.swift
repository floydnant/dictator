import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// This uses an input-only AUHAL rather than `AVAudioEngine`. On macOS, `AVAudioEngine`
/// opens both the default input and output devices even when the graph only has an input
/// tap. If the output is AirPlay, Core Audio builds an aggregate device and can spend four
/// seconds trying to start it before failing. Dictation has no output path, so it should not
/// depend on the selected speaker at all.
final class AudioCapture: @unchecked Sendable {
    private nonisolated(unsafe) var audioUnit: AudioUnit?
    private nonisolated(unsafe) var nativeFormat: AVAudioFormat?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var didLogRenderFailure = false
    private var isRunning = false

    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard !isRunning else { return }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.componentUnavailable
        }

        var candidate: AudioUnit?
        try Self.check(
            AudioComponentInstanceNew(component, &candidate),
            operation: "create the microphone input"
        )
        guard let unit = candidate else { throw CaptureError.componentUnavailable }

        do {
            var enabled: UInt32 = 1
            try Self.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1,
                    &enabled,
                    UInt32(MemoryLayout.size(ofValue: enabled))
                ),
                operation: "enable microphone input"
            )

            // AUHAL defaults to output-only. Turning output off is the important part: the
            // current AirPlay speaker can disappear or stall without touching this unit.
            var disabled: UInt32 = 0
            try Self.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &disabled,
                    UInt32(MemoryLayout.size(ofValue: disabled))
                ),
                operation: "disable unused audio output"
            )

            var device = try Self.defaultInputDevice()
            try Self.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &device,
                    UInt32(MemoryLayout.size(ofValue: device))
                ),
                operation: "select the default microphone"
            )

            var streamDescription = AudioStreamBasicDescription()
            var streamDescriptionSize = UInt32(MemoryLayout.size(ofValue: streamDescription))
            try Self.check(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    1,
                    &streamDescription,
                    &streamDescriptionSize
                ),
                operation: "read the microphone format"
            )
            // The client side of a fresh AUHAL defaults to 44.1 kHz stereo, regardless of
            // the microphone. Asking a mono 48 kHz device to render into that untouched
            // format fails every callback with kAudioUnitErr_CannotDoInCurrentContext.
            // Use the device format here. `AVAudioConverter` below handles the speech
            // engine's format separately.
            try Self.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    1,
                    &streamDescription,
                    streamDescriptionSize
                ),
                operation: "configure the microphone format"
            )
            guard let nativeFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.invalidInputFormat
            }

            self.audioUnit = unit
            self.nativeFormat = nativeFormat
            self.outputFormat = outputFormat
            converter = nativeFormat == outputFormat
                ? nil
                : AVAudioConverter(from: nativeFormat, to: outputFormat)
            self.onBuffer = onBuffer
            self.onLevel = onLevel
            didLogRenderFailure = false

            var callback = AURenderCallbackStruct(
                inputProc: dictatorInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &callback,
                    UInt32(MemoryLayout.size(ofValue: callback))
                ),
                operation: "install the microphone callback"
            )

            try Self.check(AudioUnitInitialize(unit), operation: "initialize the microphone")
            try Self.check(AudioOutputUnitStart(unit), operation: "start the microphone")
            isRunning = true
            Log.audio.info(
                "capture started - native \(nativeFormat.sampleRate)Hz/\(nativeFormat.channelCount)ch -> engine \(outputFormat.sampleRate)Hz/\(outputFormat.channelCount)ch"
            )
        } catch {
            dispose(unit)
            throw error
        }
    }

    func stop() {
        guard let unit = audioUnit else { return }
        dispose(unit)
        Log.audio.info("capture stopped")
    }

    // MARK: - Audio thread

    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit,
              let nativeFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: frameCount)
        else { return kAudio_ParamError }

        buffer.frameLength = frameCount
        let status = AudioUnitRender(
            unit,
            flags,
            timestamp,
            1,
            frameCount,
            buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            if !didLogRenderFailure {
                didLogRenderFailure = true
                Log.audio.error("microphone render failed with Core Audio error \(status)")
            }
            return status
        }

        handle(buffer)
        return noErr
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onLevel?(Self.rms(of: buffer))
        guard let outputFormat else { return }

        guard let converter else {
            if let copy = Self.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    private func dispose(_ unit: AudioUnit) {
        if isRunning { AudioOutputUnitStop(unit) }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        nativeFormat = nil
        converter = nil
        outputFormat = nil
        onBuffer = nil
        onLevel = nil
        isRunning = false
    }

    // MARK: - Setup helpers

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &device
            ),
            operation: "find the default microphone"
        )
        guard device != kAudioObjectUnknown else { throw CaptureError.noInputDevice }
        return device
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else { throw CaptureError.coreAudio(operation, status) }
    }

    private enum CaptureError: LocalizedError {
        case componentUnavailable
        case invalidInputFormat
        case noInputDevice
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .componentUnavailable: "macOS could not create a microphone input."
            case .invalidInputFormat: "The selected microphone has no usable audio format."
            case .noInputDevice: "No microphone is selected in System Settings."
            case .coreAudio(let operation, let status):
                "Could not \(operation) (Core Audio error \(status))."
            }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    private final class Latch: @unchecked Sendable {
        private var fired = false
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}

/// C audio callbacks cannot capture context. AUHAL hands the `AudioCapture` instance back
/// through `inputProcRefCon`, and the unit is stopped before that instance can go away.
private func dictatorInputCallback(
    _ refcon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<AudioCapture>.fromOpaque(refcon).takeUnretainedValue()
    return capture.render(flags: flags, timestamp: timestamp, frameCount: frameCount)
}
