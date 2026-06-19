import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MediaPlaybackController")
struct MediaPlaybackControllerTests {
    @Test("disabled setting is a no-op")
    func disabledSettingIsNoOp() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: false, routeKind: .speakerLike)
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 0)
    }

    @Test("already-paused media is left alone throughout")
    func alreadyPausedMediaIsLeftAlone() {
        // Paused video reports "not playing" via now-playing state, even though
        // IsRunningOutput would (incorrectly) read active. The press must be a
        // no-op so the blind play/pause key does not start the paused media,
        // and the release must not toggle either.
        let client = FakeMediaPlaybackClient(playbackState: .notPlaying)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 0)
    }

    @Test("unknown playback state is a no-op on press")
    func unknownPlaybackStateIsNoOpOnPress() {
        // If we cannot positively confirm audio is playing, do not risk
        // un-pausing already-paused media.
        let client = FakeMediaPlaybackClient(playbackState: .unknown)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 0)
    }

    @Test("headphone output is skipped")
    func headphoneOutputIsSkipped() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .headphoneLike)
        controller.waitForIdle()

        #expect(client.toggleCalls == 0)
    }

    @Test("playing media pauses and restores")
    func playingMediaPausesAndRestores() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        #expect(client.toggleCalls == 1)

        // After pausing, now-playing reports not playing; the resume toggle fires.
        client.playbackState = .notPlaying
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 2)
    }

    @Test("restore does not toggle if user already resumed playback")
    func restoreDoesNotToggleResumedPlayback() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        // The user resumed/started playback during the session; resuming again
        // would instead pause it, so the restore must be skipped.
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 1)
    }

    @Test("restore resumes when playback state is unknown")
    func restoreResumesWhenPlaybackStateIsUnknown() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        client.playbackState = .unknown
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 2)
    }

    @Test("duplicate begin only pauses once")
    func duplicateBeginOnlyPausesOnce() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()

        #expect(client.toggleCalls == 1)
    }

    private func makeController(client: FakeMediaPlaybackClient) -> MediaPlaybackController {
        MediaPlaybackController(
            client: client,
            queue: DispatchQueue(label: "test.media-playback")
        )
    }
}

private final class FakeMediaPlaybackClient: MediaPlaybackClient {
    var playbackState: MediaPlaybackState
    var toggleCalls = 0

    init(playbackState: MediaPlaybackState) {
        self.playbackState = playbackState
    }

    func nowPlayingPlaybackState() -> MediaPlaybackState {
        playbackState
    }

    func sendMediaPlayPauseToggle() {
        toggleCalls += 1
    }
}
