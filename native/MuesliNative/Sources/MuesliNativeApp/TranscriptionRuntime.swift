import FluidAudio
import Foundation
import MuesliCore

struct SpeechSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
}

/// A loose `[min, max]` speaker-count constraint for offline diarization,
/// typically derived from a calendar event's attendee count. Applied as a ceiling
/// only — the diarizer detects the real count within the band. Exact counts are
/// deliberately avoided because invitees are not the same as speakers.
struct DiarizationSpeakerBounds: Sendable, Equatable {
    let minSpeakers: Int
    let maxSpeakers: Int

    /// Upper clamp on the derived maximum. Diarization accuracy degrades as the
    /// speaker count grows, and large invites (all-hands) rarely have more than a
    /// handful of *active* speakers, so a 40-person invite must not set max=40.
    static let maxSpeakerClamp = 8

    /// Derive a loose constraint from a calendar event's attendee count.
    ///
    /// Used as a ceiling only: `minSpeakers = 1` (a channel may have a single
    /// active speaker even in a crowded meeting), `maxSpeakers = min(count, clamp)`.
    /// The count is a valid upper bound on the distinct voices in any single audio
    /// channel — a channel cannot contain more speakers than the meeting has
    /// attendees. We never set an exact count: no-shows, silent listeners, and
    /// shared conference-room endpoints all push the true count below the invite.
    ///
    /// Returns `nil` (no constraint) when there is no usable signal: no linked
    /// event, or a count of 0/1 that cannot distinguish speakers.
    static func fromAttendeeCount(_ count: Int?) -> DiarizationSpeakerBounds? {
        guard let count, count >= 2 else { return nil }
        return DiarizationSpeakerBounds(minSpeakers: 1, maxSpeakers: min(count, maxSpeakerClamp))
    }
}

actor TranscriptionCoordinator {
    static let explicitlyRoutedBackendIdentifiers: Set<String> = [
        "whisper", "nemotron35", "cohere", "indicasr", "sensevoice",
    ]

    private let fluidTranscriber = FluidAudioTranscriber()
    private let whisperTranscriber = WhisperKitTranscriber()
    private var _qwen3PostProcessor: Any?
    private var _cohereTranscriber: Any?
    private var _indicASRTranscriber: Any?
    private let senseVoiceTranscriber = SenseVoiceTranscriber()
    private var vadManager: VadManager?
    /// Offline diarization models are loaded once and reused. Speaker-count bounds
    /// vary per meeting, so each diarization spins up a lightweight
    /// `OfflineDiarizerManager` around these shared (already-compiled) models.
    private var offlineDiarizerModels: OfflineDiarizerModels?
    private var activeBackend: String?

    private var _nemotron35Transcriber: Any?
    /// Selected Nemotron 3.5 language prompt id (101 = auto). Stored so it survives
    /// lazy (re)creation of the transcriber and is applied whenever it loads.
    private var nemotron35PromptId: Int32 = 101

    @available(macOS 15, *)
    private var nemotron35Transcriber: Nemotron35StreamingTranscriber {
        if _nemotron35Transcriber == nil {
            _nemotron35Transcriber = Nemotron35StreamingTranscriber()
        }
        return _nemotron35Transcriber as! Nemotron35StreamingTranscriber
    }

    /// Loaded accessor for production dictation paths. Preload normally warms the
    /// model, but direct hold-to-talk or early double-tap after relaunch must not
    /// reach the actor while its CoreML models are still unloaded.
    @available(macOS 15, *)
    func getLoadedNemotron35Transcriber(
        progress: ((Double, String?) -> Void)? = nil
    ) async throws -> Nemotron35StreamingTranscriber {
        let transcriber = nemotron35Transcriber
        await transcriber.setPromptId(nemotron35PromptId)
        try await transcriber.loadModels(progress: progress)
        return transcriber
    }

    /// Set the Nemotron 3.5 language prompt id (from app config). Applies to the
    /// live transcriber if it already exists.
    func setNemotron35PromptId(_ id: Int32) async {
        nemotron35PromptId = id
        if #available(macOS 15, *), let t = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await t.setPromptId(id)
        }
    }

    func unloadNemotron35Transcriber() async {
        if #available(macOS 15, *), let transcriber = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await transcriber.shutdown()
        }
    }

    private var postProcessorModelURL: URL = PostProcessorOption.defaultOption.modelURL
    private var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    private var postProcessorModelId: String = PostProcessorOption.defaultOption.id
    private var postProcessorBackend: TranscriptCleanupBackendOption = .local
    private var postProcessorConfig: AppConfig = AppConfig()

    private struct PostProcessorSnapshot {
        let backend: TranscriptCleanupBackendOption
        let systemPrompt: String
        let modelId: String
        let config: AppConfig
    }

    @available(macOS 15, *)
    private var qwen3PostProcessor: Qwen3PostProcessor {
        if _qwen3PostProcessor == nil {
            _qwen3PostProcessor = Qwen3PostProcessor(
                modelURL: postProcessorModelURL,
                systemPrompt: postProcessorSystemPrompt
            )
        }
        return _qwen3PostProcessor as! Qwen3PostProcessor
    }

    @available(macOS 15, *)
    func setActivePostProcessor(option: PostProcessorOption, systemPrompt: String) async {
        await configurePostProcessor(
            backend: .local,
            option: option,
            systemPrompt: systemPrompt,
            config: postProcessorConfig
        )
    }

    func configurePostProcessor(
        backend: TranscriptCleanupBackendOption,
        option: PostProcessorOption?,
        systemPrompt: String,
        config: AppConfig
    ) async {
        postProcessorBackend = backend
        postProcessorSystemPrompt = systemPrompt
        postProcessorConfig = config

        if let option {
            postProcessorModelURL = option.modelURL
            postProcessorModelId = option.id
            if #available(macOS 15, *), let existing = _qwen3PostProcessor as? Qwen3PostProcessor {
                await existing.reconfigure(modelURL: option.modelURL, systemPrompt: systemPrompt)
            }
        } else if !backend.isLocal {
            postProcessorModelId = TranscriptCleanupClient.configuredModel(for: backend, config: config)
        }
    }

    private struct PostProcPairLogEntry: Encodable {
        let ts: String
        let raw: String
        let processed: String
        let model: String
        let asr: String
    }

    private func logPostProcPair(raw: String, processed: String, model: String, asr: String) {
        guard Qwen3PostProcessorLogging.isPairLoggingEnabled else { return }
        let logURL = AppIdentity.supportDirectoryURL.appendingPathComponent("postproc-pairs.jsonl")
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso8601.string(from: Date())
        let entry = PostProcPairLogEntry(
            ts: ts,
            raw: raw,
            processed: processed,
            model: model,
            asr: asr
        )
        guard var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(data)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    @available(macOS 15, *)
    private var cohereTranscriber: CohereTranscribeTranscriber {
        if _cohereTranscriber == nil {
            _cohereTranscriber = CohereTranscribeTranscriber()
        }
        return _cohereTranscriber as! CohereTranscribeTranscriber
    }

    @available(macOS 15, *)
    private var indicASRTranscriber: IndicASRTranscriber {
        if _indicASRTranscriber == nil {
            _indicASRTranscriber = IndicASRTranscriber()
        }
        return _indicASRTranscriber as! IndicASRTranscriber
    }

    func preload(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        progress: ((Double, String?) -> Void)? = nil
    ) async {
        do {
            try await preloadRequired(
                backend: backend,
                enablePostProcessor: enablePostProcessor,
                includeMeetingHelpers: includeMeetingHelpers,
                progress: progress
            )
        } catch {
            fputs("[muesli-native] preload failed for \(backend.backend)/\(backend.model): \(error)\n", stderr)
        }
    }

    func preloadRequired(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        progress: ((Double, String?) -> Void)? = nil
    ) async throws {
        activeBackend = backend.backend

        if includeMeetingHelpers {
            // Meeting helpers are intentionally loaded only when the caller needs meeting behavior.
            if vadManager == nil {
                do {
                    vadManager = try await VadManager()
                    fputs("[muesli-native] Silero VAD loaded\n", stderr)
                } catch {
                    fputs("[muesli-native] VAD load failed (non-critical): \(error)\n", stderr)
                }
            }

            if offlineDiarizerModels == nil {
                do {
                    offlineDiarizerModels = try await OfflineDiarizerModels.load()
                    fputs("[muesli-native] Offline speaker diarization models loaded\n", stderr)
                } catch {
                    fputs("[muesli-native] Diarization load failed (non-critical): \(error)\n", stderr)
                }
            }
        }

        switch backend.backend {
        case "fluidaudio":
            let version: AsrModelVersion = backend.model.contains("v2") ? .v2 : .v3
            try await fluidTranscriber.loadModels(version: version, progress: progress)
        case "whisper":
            try await whisperTranscriber.loadModel(modelName: backend.model, progress: progress)
            // Warmup ANE/GPU so first dictation doesn't pay CoreML compilation cost
            fputs("[muesli-native] WhisperKit warmup: running silent audio for CoreML compilation...\n", stderr)
            progress?(0.9, "Warming up model...")
            try await whisperTranscriber.warmup()
            fputs("[muesli-native] WhisperKit warmup complete\n", stderr)
            progress?(1.0, nil)
        case "nemotron35":
            if #available(macOS 15, *) {
                let transcriber = try await getLoadedNemotron35Transcriber(progress: progress)
                // Warmup ANE so first dictation starts instantly
                fputs("[muesli-native] Nemotron 3.5 warmup: running silent chunk for ANE compilation...\n", stderr)
                var state = try await transcriber.makeStreamState()
                let silence = [Float](repeating: 0, count: transcriber.chunkSamples)
                _ = try await transcriber.transcribeChunk(samples: silence, state: &state)
                fputs("[muesli-native] Nemotron 3.5 warmup complete\n", stderr)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
                ])
            }
        case "cohere":
            if #available(macOS 15, *) {
                try await cohereTranscriber.prepare(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
                ])
            }
        case "indicasr":
            if #available(macOS 15, *) {
                try await indicASRTranscriber.prepare(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR requires macOS 15 or later.",
                ])
            }
        case "sensevoice":
            try await senseVoiceTranscriber.loadModels(progress: progress)
        default:
            throw NSError(domain: "MuesliTranscriptionRuntime", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Unknown transcription backend: \(backend.backend)",
            ])
        }

        await preloadPostProcessorIfNeeded(enabled: enablePostProcessor)
    }

    func preloadPostProcessorIfNeeded(enabled: Bool) async {
        if enabled, postProcessorBackend == .local, #available(macOS 15, *) {
            do {
                try await qwen3PostProcessor.prepare()
            } catch {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor preload failed: \(error)")
            }
        }
    }

    private func currentPostProcessorSnapshot() -> PostProcessorSnapshot {
        PostProcessorSnapshot(
            backend: postProcessorBackend,
            systemPrompt: postProcessorSystemPrompt,
            modelId: postProcessorModelId,
            config: postProcessorConfig
        )
    }

    func transcribeDictation(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage,
        enablePostProcessor: Bool = false,
        customWords: [[String: Any]] = [],
        appContext: String? = nil
    ) async throws -> SpeechTranscriptionResult {
        let postProcessorSnapshot = currentPostProcessorSnapshot()
        // Qwen3 post-processing is intentionally dictation-only. Meeting transcription should keep raw backend/Parakeet output.
        // Cohere decodes hallucinated text from silence — skip if VAD detects no speech
        if backend.backend == "cohere", let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[muesli-native] VAD: dictation is silent, skipping Cohere transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        var result = try await route(url: url, backend: backend, cohereLanguage: cohereLanguage, indicASRLanguage: indicASRLanguage)
        result = removeArtifacts(result)
        if !result.text.isEmpty {
            Qwen3PostProcessorLogging.logVerbose("Dictation raw transcript after artifact cleanup: \(result.text)")
        }
        result = await postProcessDictationIfNeeded(
            result,
            backend: backend,
            enabled: enablePostProcessor,
            postProcessorSnapshot: postProcessorSnapshot,
            appContext: appContext
        ) ?? removeFillersWithLogging(result)
        let final = applyCustomWords(result, customWords: customWords)
        if !final.text.isEmpty {
            Qwen3PostProcessorLogging.logVerbose("Dictation final transcript: \(final.text)")
        }
        return final
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage
    ) async throws -> SpeechTranscriptionResult {
        // Meetings intentionally skip Qwen/custom-word post-processing. Keep deterministic artifact/filler cleanup only.
        cleanMeetingTranscript(try await route(url: url, backend: backend, cohereLanguage: cohereLanguage, indicASRLanguage: indicASRLanguage))
    }

    func transcribeMeetingChunk(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage
    ) async throws -> SpeechTranscriptionResult {
        // Meeting chunks intentionally skip Qwen/custom-word post-processing for reconciliation.
        // Run VAD to skip silent chunks (prevents hallucinations)
        if let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[muesli-native] VAD: chunk is silent, skipping transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        return cleanMeetingTranscript(try await route(url: url, backend: backend, cohereLanguage: cohereLanguage, indicASRLanguage: indicASRLanguage))
    }

    /// Diarize a single-channel recording with the offline pipeline.
    ///
    /// `speakerBounds`, when provided (typically from a calendar event's attendee
    /// count), is applied as a loose `[min, max]` ceiling on the clustering — the
    /// diarizer still detects the actual count within the band. Exact counts are
    /// intentionally never forced, because invitees are not the same as speakers.
    /// The zero-vote re-embed post-pass (FluidAudio #751) is enabled to stop clean
    /// speaker turns from being absorbed into a neighbor's segment.
    func diarize(at url: URL, speakerBounds: DiarizationSpeakerBounds? = nil) async throws -> DiarizationResult? {
        guard let offlineDiarizerModels else {
            fputs("[muesli-native] diarization not available, skipping\n", stderr)
            return nil
        }
        let boundsLabel = speakerBounds.map { "\($0.minSpeakers)-\($0.maxSpeakers)" } ?? "none"
        fputs("[muesli-native] running offline speaker diarization (bounds=\(boundsLabel))...\n", stderr)

        let community = OfflineDiarizerConfig.Clustering.community
        let clustering = OfflineDiarizerConfig.Clustering(
            threshold: community.threshold,
            warmStartFa: community.warmStartFa,
            warmStartFb: community.warmStartFb,
            minSpeakers: speakerBounds?.minSpeakers,
            maxSpeakers: speakerBounds?.maxSpeakers,
            numSpeakers: nil
        )
        let config = OfflineDiarizerConfig(
            clustering: clustering,
            zeroVoteReembed: OfflineDiarizerConfig.ZeroVoteReembed(enabled: true)
        )
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: offlineDiarizerModels)

        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        let result = try await manager.process(audio: samples)
        let speakerCount = Set(result.segments.map(\.speakerId)).count
        fputs("[muesli-native] diarization complete: \(result.segments.count) segments, \(speakerCount) speakers\n", stderr)
        return result
    }

    func getVadManager() -> VadManager? {
        vadManager
    }

    func shutdown() async {
        await fluidTranscriber.shutdown()
        await whisperTranscriber.shutdown()
        await senseVoiceTranscriber.shutdown()
        if #available(macOS 15, *) {
            if let nemotron35 = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
                await nemotron35.shutdown()
            }
            if let postProcessor = _qwen3PostProcessor as? Qwen3PostProcessor {
                await postProcessor.shutdown()
            }
            await cohereTranscriber.shutdown()
            await indicASRTranscriber.shutdown()
        }
    }

    private func removeFillers(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = FillerWordFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: result.segments)
    }

    private func removeFillersWithLogging(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let start = CFAbsoluteTimeGetCurrent()
        let filtered = removeFillers(result)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if filtered.text != result.text {
            Qwen3PostProcessorLogging.logVerbose("FillerWordFilter applied in \(String(format: "%.1f", elapsedMs))ms -> \(filtered.text)")
        } else {
            Qwen3PostProcessorLogging.logVerbose("FillerWordFilter skipped effective changes (\(String(format: "%.1f", elapsedMs))ms)")
        }
        return filtered
    }

    private func cleanMeetingTranscript(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        removeFillers(removeArtifacts(result))
    }

    private func removeArtifacts(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = TranscriptionEngineArtifactsFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: filtered.isEmpty ? [] : result.segments)
    }

    private func postProcessDictationIfNeeded(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        enabled: Bool,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String? = nil
    ) async -> SpeechTranscriptionResult? {
        guard enabled else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor disabled for dictation")
            return nil
        }
        guard backend.backend != "indicasr" else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor skipped: Indic ASR output is not English post-processor safe")
            return nil
        }
        guard !result.text.isEmpty else {
            Qwen3PostProcessorLogging.logVerbose("Post-processor skipped: empty transcript")
            return nil
        }
        if !postProcessorSnapshot.backend.isLocal {
            return await postProcessDictationWithHostedBackend(
                result,
                backend: backend,
                postProcessorSnapshot: postProcessorSnapshot,
                appContext: appContext
            )
        }
        guard #available(macOS 15, *) else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor skipped: requires macOS 15+")
            return nil
        }

        do {
            // The explicit toggle means "always try cleanup" for dictation.
            // Trigger heuristics were removed; the only remaining heuristic here preserves deletion-cue empty output.
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor forced by toggle")
            let start = CFAbsoluteTimeGetCurrent()
            let processed = try await qwen3PostProcessor.process(result.text, appContext: appContext)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !Qwen3DeletionCueDetector.containsDeletionCue(result.text) {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back")
                TranscriptCleanupDebugLogger.append(
                    status: "fallback_empty_output",
                    cleanupBackend: postProcessorSnapshot.backend,
                    cleanupModel: postProcessorSnapshot.modelId,
                    asrBackend: backend.backend,
                    appContextText: appContext,
                    rawASRText: result.text,
                    rawCleanupOutputText: processed,
                    cleanupOutputText: trimmed,
                    elapsedMs: elapsedMs
                )
                return nil
            }
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor final output: \(trimmed)")
            logPostProcPair(raw: result.text, processed: trimmed, model: postProcessorSnapshot.modelId, asr: backend.backend)
            TranscriptCleanupDebugLogger.append(
                status: "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: processed,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                // Original ASR segments describe pre-cleanup text. Keep them only for debug diagnostics.
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    private func postProcessDictationWithHostedBackend(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String?
    ) async -> SpeechTranscriptionResult? {
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let cleanup = try await TranscriptCleanupClient.clean(
                text: result.text,
                systemPrompt: postProcessorSnapshot.systemPrompt,
                appContext: appContext,
                backend: postProcessorSnapshot.backend,
                config: postProcessorSnapshot.config
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let trimmed = cleanup.cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !Qwen3DeletionCueDetector.containsDeletionCue(result.text) {
                Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back")
                TranscriptCleanupDebugLogger.append(
                    status: "fallback_empty_output",
                    cleanupBackend: postProcessorSnapshot.backend,
                    cleanupModel: cleanup.model,
                    asrBackend: backend.backend,
                    appContextText: appContext,
                    rawASRText: result.text,
                    rawCleanupOutputText: cleanup.rawOutput,
                    cleanupOutputText: trimmed,
                    elapsedMs: elapsedMs
                )
                return nil
            }
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))")
            logPostProcPair(raw: result.text, processed: trimmed, model: cleanup.model, asr: backend.backend)
            TranscriptCleanupDebugLogger.append(
                status: "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: cleanup.model,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: cleanup.rawOutput,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch TranscriptCleanupError.rejectedOutput {
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor output rejected, falling back")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_rejected_output",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: TranscriptCleanupError.rejectedOutput.localizedDescription
            )
            return nil
        } catch {
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    private func applyCustomWords(_ result: SpeechTranscriptionResult, customWords: [[String: Any]]) -> SpeechTranscriptionResult {
        guard !customWords.isEmpty, !result.text.isEmpty else { return result }
        let entries = customWords.compactMap { dict -> CustomWord? in
            guard let word = dict["word"] as? String else { return nil }
            let threshold = dict["matchingThreshold"] as? Double ?? 0.85
            return CustomWord(word: word, replacement: dict["replacement"] as? String, matchingThreshold: threshold)
        }
        guard !entries.isEmpty else { return result }
        let correctedText = CustomWordMatcher.apply(text: result.text, customWords: entries)
        return SpeechTranscriptionResult(text: correctedText, segments: result.segments)
    }

    private func route(
        url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        switch backend.backend {
        case "whisper":
            return try await transcribeWithWhisperKit(url: url)
        case "nemotron35":
            return try await transcribeWithNemotron35(url: url)
        case "cohere":
            return try await transcribeWithCohere(url: url, language: cohereLanguage)
        case "indicasr":
            return try await transcribeWithIndicASR(url: url, language: indicASRLanguage)
        case "sensevoice":
            return try await transcribeWithSenseVoice(url: url)
        default:
            return try await transcribeWithFluidAudio(url: url)
        }
    }

    // MARK: - FluidAudio (Parakeet on ANE)

    private func transcribeWithFluidAudio(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with FluidAudio: \(url.lastPathComponent)\n", stderr)
        let result = try await fluidTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] FluidAudio result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = (result.tokenTimings ?? []).map { timing in
            SpeechSegment(start: timing.startTime, end: timing.endTime, text: timing.token)
        }
        return SpeechTranscriptionResult(
            text: text,
            segments: segments.isEmpty && !text.isEmpty ? [SpeechSegment(start: 0, end: result.duration, text: text)] : segments
        )
    }

    // MARK: - WhisperKit (Whisper on ANE/GPU via CoreML)

    private func transcribeWithWhisperKit(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with WhisperKit: \(url.lastPathComponent)\n", stderr)
        let result = try await whisperTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] WhisperKit result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - SenseVoiceSmall (FunASR via FluidAudio/CoreML)

    private func transcribeWithSenseVoice(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with SenseVoice: \(url.lastPathComponent)\n", stderr)
        let result = try await senseVoiceTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] SenseVoice result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            // FluidAudio's SenseVoice API returns plain text only, so timestamped segments are not available here.
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Cohere Transcribe (CoreML)

    private func transcribeWithCohere(
        url: URL,
        language: CohereTranscribeLanguage
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Cohere Transcribe: \(url.lastPathComponent)\n", stderr)
            let result = try await cohereTranscriber.transcribe(wavURL: url, language: language)
            fputs("[muesli-native] Cohere Transcribe result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Indic ASR (AI4Bharat IndicConformer RNNT CoreML)

    private func transcribeWithIndicASR(
        url: URL,
        language: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            IndicASRLogging.logVerbose("transcribing with Indic ASR (\(language.rawValue)): \(url.lastPathComponent)")
            let result = try await indicASRTranscriber.transcribe(wavURL: url, language: language)
            IndicASRLogging.logVerbose("Indic ASR result chars=\(result.text.count), processingTime=\(String(format: "%.3f", result.processingTime))s")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Indic ASR requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Nemotron 3.5 Streaming (RNNT CoreML on ANE)

    private func transcribeWithNemotron35(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Nemotron 3.5: \(url.lastPathComponent)\n", stderr)
            let transcriber = try await getLoadedNemotron35Transcriber()
            let result = try await transcriber.transcribe(wavURL: url)
            fputs("[muesli-native] Nemotron 3.5 result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
            ])
        }
    }

}
