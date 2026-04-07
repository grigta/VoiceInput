import AVFoundation

enum AudioError: Error, LocalizedError {
    case converterCreationFailed
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .microphonePermissionDenied:
            return "Microphone access denied"
        }
    }
}

class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    var isRecording: Bool { engine.isRunning }

    func startRecording() throws {
        bufferLock.lock()
        audioBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw AudioError.converterCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) {
            [weak self] buffer, _ in
            self?.convert(buffer: buffer, converter: converter)
        }

        engine.prepare()
        try engine.start()
    }

    func stopRecording() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        bufferLock.lock()
        let result = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        return result
    }

    private func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCount = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCount
        ) else { return }

        var error: NSError?
        var hasData = true
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if let channelData = outputBuffer.floatChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(
                start: channelData,
                count: Int(outputBuffer.frameLength)
            ))
            bufferLock.lock()
            audioBuffer.append(contentsOf: samples)
            bufferLock.unlock()
        }
    }
}
