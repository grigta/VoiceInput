import Foundation
import whisper

enum WhisperError: Error, LocalizedError {
    case couldNotInitializeContext
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .couldNotInitializeContext:
            return "Failed to load whisper model"
        case .transcriptionFailed(let code):
            return "Transcription failed with code \(code)"
        }
    }
}

actor WhisperContext {
    private var context: OpaquePointer

    private init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    static func create(modelPath: String) throws -> WhisperContext {
        print("[Whisper] Loading model: \(modelPath)")
        var params = whisper_context_default_params()
        params.flash_attn = false
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.couldNotInitializeContext
        }
        print("[Whisper] Model loaded successfully")
        return WhisperContext(context: ctx)
    }

    func transcribe(_ rawSamples: [Float]) throws -> String {
        // Normalize audio to peak ~0.9
        let samples: [Float]
        let peak = rawSamples.map { abs($0) }.max() ?? 0
        if peak > 0.001 && peak < 0.5 {
            let gain = 0.9 / peak
            samples = rawSamples.map { $0 * gain }
            print("[Whisper] Normalized: peak \(String(format: "%.4f", peak)) → gain \(String(format: "%.1f", gain))x")
        } else {
            samples = rawSamples
        }

        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))

        print("[Whisper] Running inference on \(samples.count) samples (\(String(format: "%.1f", Float(samples.count)/16000))s) with \(maxThreads) threads...")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Run twice — once as English, once as Russian — pick the one with more text
        let enResult = runInference(samples: samples, language: "en", threads: maxThreads)
        let ruResult = runInference(samples: samples, language: "ru", threads: maxThreads)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[Whisper] EN: '\(enResult)' | RU: '\(ruResult)' | \(String(format: "%.2f", elapsed))s")

        // Pick the longer non-empty result
        let result: String
        if enResult.isEmpty && ruResult.isEmpty {
            result = ""
        } else if enResult.isEmpty {
            result = ruResult
        } else if ruResult.isEmpty {
            result = enResult
        } else {
            // Both have text — pick the longer one (more content = better recognition)
            result = enResult.count >= ruResult.count ? enResult : ruResult
        }

        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[Whisper] Total: \(String(format: "%.2f", totalElapsed))s | Final: '\(result)'")
        return result
    }

    private func runInference(samples: [Float], language: String, threads: Int) -> String {
        let code: Int32 = language.withCString { lang in
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false
            params.language = lang
            params.detect_language = false
            params.n_threads = Int32(threads)
            params.offset_ms = 0
            params.no_context = true
            params.single_segment = false
            params.suppress_non_speech_tokens = false
            params.suppress_blank = false

            return samples.withUnsafeBufferPointer { buf in
                whisper_full(context, params, buf.baseAddress, Int32(buf.count))
            }
        }

        guard code == 0 else { return "" }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segText = whisper_full_get_segment_text(context, i) {
                text += String(cString: segText)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
