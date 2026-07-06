import Foundation
import ProsodyKit

// MARK: - Model Store / Installer

/// Download + install + delete support for the audEERING audio-valence
/// (`wav2vec2-msp-dim-emotion`) CoreML model, published as a 3-file `.mlpackage`
/// on Hugging Face. Mirrors `CohereTranscribeModelStore`: each relative path is
/// fetched from the HF `resolve/main` base URL via ``downloadWithRetry`` (which
/// itself downloads to a temp file and moves it into place), preserving the
/// `.mlpackage` subdirectory structure under Muesli's runtime model cache.
///
/// The model is auxiliary — it is NOT a selectable transcription `BackendOption`.
/// When absent, `SpeechEmotionBackend` returns nil and prosody degrades to
/// text-only fusion (VADER + acoustic).
///
/// Lives in the app (not ProsodyKit) because it downloads over the network via the
/// app's `downloadWithRetry`. The install *detection* + cache paths are owned by
/// `ProsodyKit.SpeechEmotionBackend`, which this delegates to so both agree.
enum AudioValenceModelInstaller {
    static let repoId = "ahamino/wav2vec2-msp-dim-emotion-coreml"

    /// Public landing page (shown as a "Model card" link in the UI).
    static let huggingFaceURL = URL(string: "https://huggingface.co/\(repoId)")!

    /// True when the model can be loaded (delegates to ProsodyKit's file detection).
    static var isModelInstalled: Bool {
        SpeechEmotionBackend.isModelInstalled
    }

    /// Remote HF URL for a relative `.mlpackage` path. Mirrors
    /// `CohereTranscribeModelStore.remoteURL(for:)`.
    static func remoteURL(for relativePath: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(repoId)/resolve/main")!
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "download", value: "1")]
        return components.url!
    }

    /// Download the three `.mlpackage` files into the runtime cache, preserving
    /// structure. Coarse per-file progress (`0...1`). Cleans partial files on
    /// failure. No-op if already installed.
    static func downloadModel(progress: @Sendable (Double) -> Void) async throws {
        if SpeechEmotionBackend.isModelInstalled {
            progress(1.0)
            return
        }
        let fm = FileManager.default
        let cacheDirectory = SpeechEmotionBackend.cacheDirectory
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let packageURL = cacheDirectory.appendingPathComponent(SpeechEmotionBackend.packageName, isDirectory: true)
        let missing = SpeechEmotionBackend.requiredRelativeFiles.filter {
            !fm.fileExists(atPath: cacheDirectory.appendingPathComponent($0).path)
        }
        let total = max(missing.count, 1)
        do {
            for (index, relativePath) in missing.enumerated() {
                try Task.checkCancellation()
                progress(Double(index) / Double(total))
                let destination = cacheDirectory.appendingPathComponent(relativePath)
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await downloadWithRetry(from: remoteURL(for: relativePath), to: destination)
            }
            progress(1.0)
        } catch {
            // Clean any partial `.mlpackage` so a retry starts from scratch and
            // `isModelInstalled` never reports a half-downloaded model.
            try? fm.removeItem(at: packageURL)
            throw error
        }
    }

    /// Remove the installed model (both the raw `.mlpackage` and any compiled
    /// `.mlmodelc`) from the runtime cache.
    static func deleteModel() throws {
        let fm = FileManager.default
        let packageURL = SpeechEmotionBackend.cacheDirectory
            .appendingPathComponent(SpeechEmotionBackend.packageName, isDirectory: true)
        if fm.fileExists(atPath: packageURL.path) {
            try fm.removeItem(at: packageURL)
        }
        let compiled = SpeechEmotionBackend.compiledModelURL
        if fm.fileExists(atPath: compiled.path) {
            try fm.removeItem(at: compiled)
        }
    }
}
