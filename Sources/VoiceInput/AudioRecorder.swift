import AVFoundation
import Accelerate

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
    private var rawBuffers: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()

    var isRecording: Bool { engine.isRunning }

    func startRecording() throws {
        bufferLock.lock()
        rawBuffers.removeAll()
        bufferLock.unlock()

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        print("[Audio] Hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch, \(hwFormat.commonFormat.rawValue)")

        // Print active input device info
        #if os(macOS)
        if let inputDesc = engine.inputNode.auAudioUnit.deviceID as? UInt32 {
            print("[Audio] Input device ID: \(inputDesc)")
        }
        #endif

        // Capture raw hardware buffers — convert later in one shot
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }
            // Copy buffer (tap buffer is reused)
            guard let copy = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(hwFormat.channelCount) {
                    memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }
            self.bufferLock.lock()
            self.rawBuffers.append(copy)
            self.bufferLock.unlock()
        }

        engine.prepare()
        try engine.start()
    }

    func stopRecording() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        bufferLock.lock()
        let buffers = rawBuffers
        rawBuffers.removeAll()
        bufferLock.unlock()

        guard !buffers.isEmpty else { return [] }

        let hwFormat = buffers[0].format

        // Calculate total frame count
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        print("[Audio] Captured \(totalFrames) raw frames at \(hwFormat.sampleRate)Hz")

        // Concatenate all buffers into one
        guard let combined = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            print("[Audio] Failed to create combined buffer")
            return []
        }
        combined.frameLength = AVAudioFrameCount(totalFrames)

        var offset = 0
        for buf in buffers {
            let len = Int(buf.frameLength)
            if let src = buf.floatChannelData, let dst = combined.floatChannelData {
                for ch in 0..<Int(hwFormat.channelCount) {
                    memcpy(dst[ch].advanced(by: offset), src[ch], len * MemoryLayout<Float>.size)
                }
            }
            offset += len
        }

        // Convert to 16kHz mono in one shot
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            print("[Audio] Failed to create converter")
            return extractMono(from: combined)
        }

        let ratio = 16000.0 / hwFormat.sampleRate
        let outFrameCount = AVAudioFrameCount(ceil(Double(totalFrames) * ratio))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCount) else {
            print("[Audio] Failed to create output buffer")
            return []
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return combined
            }
            outStatus.pointee = .endOfStream
            return nil
        }

        if let error = error {
            print("[Audio] Conversion error: \(error)")
        }
        print("[Audio] Conversion status: \(status.rawValue), output frames: \(outputBuffer.frameLength)")

        guard let channelData = outputBuffer.floatChannelData?[0] else { return [] }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))

        // Print audio level stats
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let maxVal = samples.map { abs($0) }.max() ?? 0
        print("[Audio] Output: \(samples.count) samples, RMS=\(String(format: "%.6f", rms)), max=\(String(format: "%.6f", maxVal))")

        // Save debug WAV to Desktop
        saveDebugWAV(samples: samples, sampleRate: 16000)

        return samples
    }

    // Fallback: just take first channel without resampling
    private func extractMono(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private func saveDebugWAV(samples: [Float], sampleRate: Int) {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/voiceinput_debug.wav")
        let numSamples = samples.count
        let dataSize = numSamples * 2  // 16-bit PCM
        let fileSize = 44 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        // Convert float to int16
        var pcmData = Data(capacity: dataSize)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767)
            pcmData.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        header.append(pcmData)
        try? header.write(to: desktop)
        print("[Audio] Debug WAV saved to: \(desktop.path)")
    }
}
