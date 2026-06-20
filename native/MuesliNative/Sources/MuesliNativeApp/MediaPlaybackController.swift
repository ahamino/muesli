import AppKit
import Darwin
import Foundation

protocol MediaPlaybackManaging: AnyObject {
    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind)
    func restoreDictationMediaPause()
}

/// Actual playback state of the system now-playing application, as opposed to
/// `AudioOutputActivityStatus`, which only reflects whether an app's audio
/// output pipeline is running. Browsers and most video players keep their
/// audio engine/IO alive while a video is *paused*, so `IsRunningOutput` (and
/// therefore `AudioOutputActivityStatus`) reports "active" for paused media
/// and cannot be used to decide whether to send a play/pause toggle.
enum MediaPlaybackState: Equatable, CustomStringConvertible {
    case playing
    case notPlaying
    case unknown

    var description: String {
        switch self {
        case .playing: return "playing"
        case .notPlaying: return "not-playing"
        case .unknown: return "unknown"
        }
    }
}

protocol MediaPlaybackClient {
    /// Whether the current now-playing application is actually producing audio.
    /// `.unknown` is returned when the signal cannot be obtained.
    func nowPlayingPlaybackState() -> MediaPlaybackState
    func sendMediaPlayPauseToggle()
}

final class MediaPlaybackController: MediaPlaybackManaging {
    private let client: MediaPlaybackClient
    private let queue: DispatchQueue
    private var pausedForSession = false

    init(
        client: MediaPlaybackClient = SystemMediaPlaybackClient(),
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.media-playback")
    ) {
        self.client = client
        self.queue = queue
    }

    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind) {
        queue.sync { [self] in
            guard enabled else { return }
            guard !pausedForSession else { return }
            guard routeKind == .speakerLike else { return }
            // The media key is a blind global toggle: sending it to already-
            // paused media would *start* playback. Only pause when we can
            // positively confirm something is actually playing. IsRunningOutput
            // cannot be used here because it stays true for paused media
            // (browsers/video players keep their audio engine alive while
            // paused), so an unknown state must also be a no-op.
            guard client.nowPlayingPlaybackState() == .playing else { return }
            client.sendMediaPlayPauseToggle()
            pausedForSession = true
        }
    }

    func restoreDictationMediaPause() {
        queue.async { [self] in
            guard pausedForSession else { return }
            pausedForSession = false
            // We only paused media we confirmed was playing, so resume it. Do
            // not gate on IsRunningOutput here: a paused video still reports
            // its audio engine as running, which would block the resume and
            // strand playback. Only skip the resume when something is actively
            // playing again (the user resumed/started playback) so we do not
            // pause it. When state is unknown, prefer restoring media we know
            // Muesli paused over leaving playback stranded.
            guard client.nowPlayingPlaybackState() != .playing else { return }
            client.sendMediaPlayPauseToggle()
        }
    }

    func waitForIdle() {
        queue.sync {}
    }
}

final class SystemMediaPlaybackClient: MediaPlaybackClient {
    private let nowPlaying = NowPlayingMediaRemoteClient()

    func nowPlayingPlaybackState() -> MediaPlaybackState {
        nowPlaying.playbackState()
    }

    func sendMediaPlayPauseToggle() {
        postAuxKey(keyCode: 16)
    }

    private func postAuxKey(keyCode: Int) {
        postAuxKeyEvent(keyCode: keyCode, keyState: 0xA)
        postAuxKeyEvent(keyCode: keyCode, keyState: 0xB)
    }

    private func postAuxKeyEvent(keyCode: Int, keyState: Int) {
        let data1 = (keyCode << 16) | (keyState << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )?.cgEvent else { return }
        event.post(tap: .cghidEventTap)
    }
}

/// Reads the system now-playing playback state through the private MediaRemote
/// framework, loaded lazily via `dlsym`. MediaRemote tracks the application
/// that owns the current "now playing" info and exposes whether it is actually
/// playing — the signal that `kAudioProcessPropertyIsRunningOutput` cannot
/// provide (an app's audio engine stays running while media is paused).
///
/// The query is asynchronous (MediaRemote delivers the result on a dispatch
/// queue), so it is turned into a synchronous call with a short timeout. The
/// private symbols have been stable across macOS releases for many years; if
/// the framework or symbol is unavailable we conservatively report `.unknown`
/// and the caller treats that as "do not toggle".
private final class NowPlayingMediaRemoteClient {
    private typealias MRNowPlayingIsPlayingHandler = @convention(block) (Bool) -> Void
    private typealias MRGetNowPlayingIsPlayingFn =
        @convention(c) (DispatchQueue, MRNowPlayingIsPlayingHandler) -> Void

    private let callbackQueue = DispatchQueue(label: "com.muesli.media-playback.now-playing")
    private let queryTimeout: DispatchTimeInterval
    private let isPlayingFn: MRGetNowPlayingIsPlayingFn?

    init(queryTimeout: DispatchTimeInterval = .milliseconds(250)) {
        self.queryTimeout = queryTimeout
        // dlopen is globally refcounted by dyld, so the framework stays loaded
        // for the process lifetime; the handle does not need to be retained.
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW | RTLD_LOCAL
        ),
            let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            self.isPlayingFn = nil
            return
        }
        self.isPlayingFn = unsafeBitCast(symbol, to: MRGetNowPlayingIsPlayingFn.self)
    }

    func playbackState() -> MediaPlaybackState {
        guard let isPlayingFn else { return .unknown }
        let semaphore = DispatchSemaphore(value: 0)
        var didCall = false
        var isPlaying = false
        let handler: MRNowPlayingIsPlayingHandler = { value in
            isPlaying = value
            didCall = true
            semaphore.signal()
        }
        isPlayingFn(callbackQueue, handler)
        if semaphore.wait(timeout: .now() + queryTimeout) == .timedOut {
            return .unknown
        }
        return didCall ? (isPlaying ? .playing : .notPlaying) : .unknown
    }
}
