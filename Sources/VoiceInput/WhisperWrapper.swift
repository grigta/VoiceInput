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
        // Don't enable flash_attn — requires Metal shader resources in specific path
        params.flash_attn = false
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.couldNotInitializeContext
        }
        print("[Whisper] Model loaded successfully")
        return WhisperContext(context: ctx)
    }

    func transcribe(_ samples: [Float]) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        params.n_threads = Int32(maxThreads)
        params.language = nil
        params.detect_language = true
        params.translate = false
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.no_context = true
        params.single_segment = false
        params.suppress_non_speech_tokens = true

        print("[Whisper] Running inference on \(samples.count) samples with \(maxThreads) threads...")
        let startTime = CFAbsoluteTimeGetCurrent()

        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(context, params, buf.baseAddress, Int32(buf.count))
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[Whisper] Inference completed in \(String(format: "%.2f", elapsed))s, result code: \(result)")

        guard result == 0 else {
            throw WhisperError.transcriptionFailed(result)
        }

        let segmentCount = whisper_full_n_segments(context)
        print("[Whisper] Segments: \(segmentCount)")
        var text = ""
        for i in 0..<segmentCount {
            if let segText = whisper_full_get_segment_text(context, i) {
                let segment = String(cString: segText)
                print("[Whisper] Segment \(i): '\(segment)'")
                text += segment
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Whisper] Final text: '\(trimmed)'")
        return trimmed
    }
}
