import Accelerate
import MuesliCore
@preconcurrency import CoreML
import Foundation

/// Native RNNT streaming ASR backend for NVIDIA Nemotron 3.5 ASR Streaming (multilingual).
/// Runs entirely on Apple Neural Engine via CoreML.
///
/// Pipeline: audio → preprocessor(mel) → encoder(with cache + prompt_id) → decoder+joint(RNNT greedy) → tokens
/// Model: FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML (multilingual/2240ms variant)
///
/// Differs from the English-only `NemotronStreamingTranscriber` in:
///   - cache_channel is [1,24,42,1024] (att_context left=42, not 70)
///   - encoder takes a 6th input `prompt_id` (language; 101 = auto-detect)
///   - vocab 13087 / blank 13087 (multilingual full vocab; punctuation is in-vocab)
///   - chunk geometry for the 2240ms tier (35840 samples / 224 mel frames / 233 total)
///   - tokenizer emits `<lang>` / `<unk>` tags that are stripped on decode
///
/// State is structurally identical to the EN backend, so this transcriber reuses
/// `NemotronStreamingTranscriber.StreamState` and conforms to `NemotronStreamingTranscribing`.
@available(macOS 15, iOS 18, *)
actor Nemotron35StreamingTranscriber: NemotronStreamingTranscribing {
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var tokenizer: [Int: String] = [:]
    private var loaded = false

    // Config from metadata.json (multilingual/2240ms variant)
    nonisolated let chunkSamples = 35840 // 2240ms at 16kHz (read cross-actor by the runtime/controller)
    private let chunkMelFrames = 224
    private let preEncodeCacheFrames = 9
    private let totalMelFrames = 233     // chunk + cache
    private let encoderOutputFrames = 28 // 224 / 8 (subsampling)
    private let encoderDim = 1024
    private let decoderHiddenSize = 640
    private let vocabSize = 13087
    private let blankTokenId = 13087     // = vocabSize (last logit)
    private let attContextLeft = 42      // cache_channel third dim
    private let promptId: Int32 = 101    // auto-detect language

    // MARK: - Streaming State (reuses the EN backend's StreamState struct)

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case downloadFailed(String)
        case preprocessingFailed(String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Nemotron 3.5 models not loaded."
            case .downloadFailed(let m): return "Download failed: \(m)"
            case .preprocessingFailed(let m): return "Preprocessing failed: \(m)"
            case .decodingFailed(let m): return "Decoding failed: \(m)"
            }
        }
    }

    // MARK: - Model Loading

    private static let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/nemotron35-multilingual-2240ms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if loaded { return }

        let modelDir = try await ensureModelsDownloaded(progress: progress)

        fputs("[nemotron35] loading CoreML models...\n", stderr)
        let config = MLModelConfiguration()
        config.computeUnits = .all

        preprocessor = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("preprocessor.mlmodelc"), configuration: config)
        encoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("encoder.mlmodelc"), configuration: config)
        decoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("decoder.mlmodelc"), configuration: config)
        joint = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("joint.mlmodelc"), configuration: config)

        // Load tokenizer: {id_string: token_string}
        let tokenizerURL = modelDir.appendingPathComponent("tokenizer.json")
        let tokenizerData = try Data(contentsOf: tokenizerURL)
        if let json = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: String] {
            for (key, value) in json {
                if let id = Int(key) {
                    tokenizer[id] = value
                }
            }
        }

        loaded = true
        fputs("[nemotron35] models ready (\(tokenizer.count) vocab tokens)\n", stderr)
    }

    // MARK: - Streaming API

    /// Create a fresh streaming state with zero-initialized caches (3.5 cache sizes).
    func makeStreamState() throws -> NemotronStreamingTranscriber.StreamState {
        let cacheChannel = try MLMultiArray(
            shape: [1, 24, NSNumber(value: attContextLeft), 1024], dataType: .float32)
        let cacheTime = try MLMultiArray(shape: [1, 24, 1024, 8], dataType: .float32)
        let cacheLen = try MLMultiArray(shape: [1], dataType: .int32)
        zeroFill(cacheChannel); zeroFill(cacheTime)
        cacheLen[0] = NSNumber(value: Int32(0))

        let hState = try MLMultiArray(shape: [2, 1, NSNumber(value: decoderHiddenSize)], dataType: .float32)
        let cState = try MLMultiArray(shape: [2, 1, NSNumber(value: decoderHiddenSize)], dataType: .float32)
        zeroFill(hState); zeroFill(cState)

        return NemotronStreamingTranscriber.StreamState(
            cacheChannel: cacheChannel, cacheTime: cacheTime, cacheLen: cacheLen,
            hState: hState, cState: cState, lastToken: 0, allTokens: []
        )
    }

    /// Process one 2240ms audio chunk (35840 samples) and return newly decoded text.
    /// State is mutated in-place to carry encoder cache + LSTM state to the next chunk.
    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String {
        guard loaded, let preprocessor, let encoder, let decoder, let joint else {
            throw TranscriberError.notLoaded
        }

        let tokensBefore = state.allTokens.count

        // 1. Preprocessor: audio → mel spectrogram
        let audioArray = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        let audioPtr = audioArray.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
        samples.withUnsafeBufferPointer { src in
            memcpy(audioPtr, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        let audioLenArray = try MLMultiArray(shape: [1], dataType: .int32)
        audioLenArray[0] = NSNumber(value: Int32(samples.count))

        let prepInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audioArray),
            "audio_length": MLFeatureValue(multiArray: audioLenArray),
        ])
        let prepOutput = try await preprocessor.prediction(from: prepInput)

        guard let mel = prepOutput.featureValue(for: "mel")?.multiArrayValue,
              let melLength = prepOutput.featureValue(for: "mel_length")?.multiArrayValue else {
            throw TranscriberError.preprocessingFailed("No mel output")
        }

        // 2. Pad/crop mel to totalMelFrames (233) for encoder
        let actualMelFrames = melLength[0].intValue
        let encoderMel = try MLMultiArray(shape: [1, 128, NSNumber(value: totalMelFrames)], dataType: .float32)
        let melSrcPtr = mel.dataPointer.bindMemory(to: Float.self, capacity: mel.count)
        let melDstPtr = encoderMel.dataPointer.bindMemory(to: Float.self, capacity: encoderMel.count)
        memset(melDstPtr, 0, encoderMel.count * MemoryLayout<Float>.size)

        let melFramesToCopy = min(mel.shape[2].intValue, totalMelFrames)
        for bin in 0..<128 {
            let srcOffset = bin * mel.shape[2].intValue
            let dstOffset = bin * totalMelFrames
            memcpy(melDstPtr.advanced(by: dstOffset), melSrcPtr.advanced(by: srcOffset), melFramesToCopy * MemoryLayout<Float>.size)
        }

        let encoderMelLen = try MLMultiArray(shape: [1], dataType: .int32)
        encoderMelLen[0] = NSNumber(value: Int32(min(actualMelFrames, totalMelFrames)))

        // 3. Encoder: mel + cache + prompt_id → encoded + new_cache
        let promptIdArray = try MLMultiArray(shape: [1], dataType: .int32)
        promptIdArray[0] = NSNumber(value: promptId)

        let encInput = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: encoderMel),
            "mel_length": MLFeatureValue(multiArray: encoderMelLen),
            "cache_channel": MLFeatureValue(multiArray: state.cacheChannel),
            "cache_time": MLFeatureValue(multiArray: state.cacheTime),
            "cache_len": MLFeatureValue(multiArray: state.cacheLen),
            "prompt_id": MLFeatureValue(multiArray: promptIdArray),
        ])
        let encOutput = try await encoder.prediction(from: encInput)

        guard let encoded = encOutput.featureValue(for: "encoded")?.multiArrayValue,
              let encodedLength = encOutput.featureValue(for: "encoded_length")?.multiArrayValue else {
            throw TranscriberError.decodingFailed("No encoder output")
        }
        if let cc = encOutput.featureValue(for: "cache_channel_out")?.multiArrayValue { state.cacheChannel = cc }
        if let ct = encOutput.featureValue(for: "cache_time_out")?.multiArrayValue { state.cacheTime = ct }
        if let cl = encOutput.featureValue(for: "cache_len_out")?.multiArrayValue { state.cacheLen = cl }

        // 4. RNNT greedy decode over encoder frames
        let numFrames = encodedLength[0].intValue
        let encodedPtr = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)

        for t in 0..<numFrames {
            // Yield periodically to let CoreML release intermediate GPU/ANE buffers.
            if t > 0 && t % 10 == 0 { await Task.yield() }

            var maxSteps = 10
            while maxSteps > 0 {
                maxSteps -= 1

                let tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
                tokenArray[0] = NSNumber(value: state.lastToken)
                let tokenLen = try MLMultiArray(shape: [1], dataType: .int32)
                tokenLen[0] = NSNumber(value: Int32(1))

                let decInput = try MLDictionaryFeatureProvider(dictionary: [
                    "token": MLFeatureValue(multiArray: tokenArray),
                    "token_length": MLFeatureValue(multiArray: tokenLen),
                    "h_in": MLFeatureValue(multiArray: state.hState),
                    "c_in": MLFeatureValue(multiArray: state.cState),
                ])
                let decOutput = try await decoder.prediction(from: decInput)

                guard let decoderOut = decOutput.featureValue(for: "decoder_out")?.multiArrayValue else {
                    throw TranscriberError.decodingFailed("No decoder output")
                }

                // Joint: encoder [1, 1024, 1] + decoder [1, 640, 1] → logits
                let encFrame = try MLMultiArray(shape: [1, NSNumber(value: encoderDim), 1], dataType: .float32)
                let encFramePtr = encFrame.dataPointer.bindMemory(to: Float.self, capacity: encoderDim)
                let encodedStride1 = encoded.strides[1].intValue
                for d in 0..<encoderDim {
                    encFramePtr[d] = encodedPtr[d * encodedStride1 + t]
                }

                let jointInput = try MLDictionaryFeatureProvider(dictionary: [
                    "encoder": MLFeatureValue(multiArray: encFrame),
                    "decoder": MLFeatureValue(multiArray: decoderOut),
                ])
                let jointOutput = try await joint.prediction(from: jointInput)

                guard let logits = jointOutput.featureValue(for: "logits")?.multiArrayValue else {
                    throw TranscriberError.decodingFailed("No joint logits")
                }

                // Argmax
                let logitsCount = logits.count
                let logitsPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: logitsCount)
                var maxVal: Float = -Float.infinity
                var maxIdx: vDSP_Length = 0
                vDSP_maxvi(logitsPtr, 1, &maxVal, &maxIdx, vDSP_Length(logitsCount))
                let predictedToken = Int(maxIdx)

                if predictedToken == blankTokenId {
                    break
                }

                state.allTokens.append(predictedToken)
                state.lastToken = Int32(predictedToken)

                if let hOut = decOutput.featureValue(for: "h_out")?.multiArrayValue,
                   let cOut = decOutput.featureValue(for: "c_out")?.multiArrayValue {
                    state.hState = hOut
                    state.cState = cOut
                }
            }
        }

        // Decode only the new tokens from this chunk
        let newTokens = Array(state.allTokens[tokensBefore...])
        return decodeTokens(newTokens, trim: false)
    }

    // MARK: - Convenience (full-file transcription)

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard loaded else { throw TranscriberError.notLoaded }

        let samples = try loadWavAsFloats(url: wavURL)
        let start = CFAbsoluteTimeGetCurrent()

        var state = try makeStreamState()
        var sampleOffset = 0

        while sampleOffset < samples.count {
            let chunkEnd = min(sampleOffset + chunkSamples, samples.count)
            let chunk = Array(samples[sampleOffset..<chunkEnd])
            _ = try await transcribeChunk(samples: chunk, state: &state)
            sampleOffset += chunkSamples
        }

        let text = decodeTokens(state.allTokens)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return (text: text, processingTime: elapsed)
    }

    func shutdown() {
        preprocessor = nil; encoder = nil; decoder = nil; joint = nil
        tokenizer = [:]; loaded = false
    }

    // MARK: - Token Decoding

    /// Decode token IDs to text. The 3.5 multilingual vocab carries native punctuation
    /// (no stripping) but emits `<lang>` / `<unk>` tag pieces that must be dropped.
    private func decodeTokens(_ tokenIds: [Int], trim: Bool = true) -> String {
        var pieces: [String] = []
        for id in tokenIds {
            guard let piece = tokenizer[id] else { continue }
            // Drop special / language-tag tokens like "<unk>", "<en-US>", "<bg-BG>".
            if piece.count >= 2, piece.hasPrefix("<"), piece.hasSuffix(">") { continue }
            pieces.append(piece)
        }
        let text = pieces.joined()
            .replacingOccurrences(of: "▁", with: " ")
        return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    // MARK: - Helpers

    private func zeroFill(_ array: MLMultiArray) {
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        memset(ptr, 0, array.count * MemoryLayout<Float>.size)
    }

    private func loadWavAsFloats(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw TranscriberError.decodingFailed("WAV too small") }
        let pcmData = data.dropFirst(44)
        let count = pcmData.count / 2
        var floats = [Float](repeating: 0, count: count)
        pcmData.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(buf[i]) / 32767.0 }
        }
        return floats
    }

    // MARK: - Model Download

    private static let repoID = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    private static let variantPath = "multilingual/2240ms"

    private func ensureModelsDownloaded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let modelDir = Self.cacheDir
        let requiredFile = modelDir.appendingPathComponent("encoder.mlmodelc/coremldata.bin")
        if FileManager.default.fileExists(atPath: requiredFile.path) {
            fputs("[nemotron35] models already cached\n", stderr)
            return modelDir
        }

        fputs("[nemotron35] downloading multilingual/2240ms variant from HuggingFace...\n", stderr)
        progress?(0.0, "Downloading Nemotron 3.5 model...")

        let hfAPI = "https://huggingface.co/api/models/\(Self.repoID)/tree/main/\(Self.variantPath)"
        var filesDownloaded = 0
        try await downloadDirectory(apiURL: hfAPI, localDir: modelDir, remotePath: Self.variantPath) {
            filesDownloaded += 1
            progress?(min(Double(filesDownloaded) / 30.0, 0.95), "Downloading Nemotron 3.5 model...")
        }

        fputs("[nemotron35] download complete\n", stderr)
        return modelDir
    }

    private func downloadDirectory(apiURL: String, localDir: URL, remotePath: String, onFileDownloaded: (() -> Void)? = nil) async throws {
        guard let url = URL(string: apiURL) else { return }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for entry in entries {
            guard let path = entry["path"] as? String, let type = entry["type"] as? String else { continue }
            let relativePath = String(path.dropFirst(remotePath.count + 1))

            // Skip the fused decoder_joint — we run decoder + joint separately (saves ~49 MB).
            if relativePath.hasPrefix("decoder_joint.mlmodelc") { continue }

            if type == "directory" {
                let subAPI = "https://huggingface.co/api/models/\(Self.repoID)/tree/main/\(path)"
                let subDir = localDir.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
                try await downloadDirectory(apiURL: subAPI, localDir: localDir, remotePath: remotePath, onFileDownloaded: onFileDownloaded)
            } else if type == "file" {
                let fileURL = URL(string: "https://huggingface.co/\(Self.repoID)/resolve/main/\(path)")!
                let localFile = localDir.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: localFile.path) { continue }

                let parentDir = localFile.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                fputs("[nemotron35] downloading \(relativePath)...\n", stderr)
                try await downloadWithRetry(from: fileURL, to: localFile)
                onFileDownloaded?()
            }
        }
    }
}
