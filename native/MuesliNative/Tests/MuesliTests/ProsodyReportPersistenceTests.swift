import Testing
import Foundation
import ProsodyKit
@testable import MuesliCore

/// Muesli-side coverage for the `MeetingRecord.prosodyReport` accessor (MuesliCore),
/// which decodes a `ProsodyReport` (from the external ProsodyKit package) out of the
/// stored `prosody_json`. The prosody analysis itself is tested in the swift-prosody
/// package; this only guards the persistence seam that lives in Muesli.
@Suite("ProsodyReport persistence")
struct ProsodyReportPersistenceTests {
    @Test("prosody report JSON round-trips through the MeetingRecord accessor")
    func reportRoundTripsThroughMeetingRecord() {
        let speaker = SpeakerProsody(
            speaker: "You", pitchMean: 120, pitchCV: 0.2,
            wordCount: 100, speakingTime: 50, span: 60, wpm: 100,
            pauseCount: 3, totalPauseTime: 5, meanPause: 1.67, longestPause: 2.5,
            fillerCount: 4, fillerRatePerMin: 4, repetitionCount: 1,
            deliveryScore: 0.1, deliveryRead: "Measured, even delivery", qualitativeNotes: ["Comfortable pace"]
        )
        let dynamics = ConversationDynamics(
            totalTalkTime: 50, talkShare: ["You": 1.0], monologueFrac: 0,
            longestMonologueSpeaker: "You", longestMonologueSeconds: 10,
            switchesPerMin: 0, turnCount: 1, meanTurnSeconds: 10, medianTurnSeconds: 10, maxTurnSeconds: 10,
            backchannelCount: 0, questionCountBySpeaker: [:],
            latencyMeanBySpeaker: [:], latencyMedianBySpeaker: [:], shareByThird: ["You": [1, 0, 0]]
        )
        let report = ProsodyReport(speakers: [speaker], dynamics: dynamics)
        let json = report.encodedJSON()
        #expect(json != nil)

        let record = MeetingRecord(
            id: 1, title: "t", startTime: "2026-01-01T00:00:00Z", durationSeconds: 60,
            rawTranscript: "", formattedNotes: "", wordCount: 0, folderID: nil,
            prosodyJSON: json
        )
        let decoded = record.prosodyReport
        #expect(decoded?.speakers.first?.speaker == "You")
        #expect(decoded?.dynamics.talkShare["You"] == 1.0)
    }
}
