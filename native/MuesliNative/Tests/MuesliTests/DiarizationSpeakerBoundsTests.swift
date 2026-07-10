import Testing
@testable import MuesliNativeApp

@Suite("DiarizationSpeakerBounds.fromAttendeeCount")
struct DiarizationSpeakerBoundsTests {

    @Test("no linked event yields no constraint")
    func nilCount() {
        #expect(DiarizationSpeakerBounds.fromAttendeeCount(nil) == nil)
    }

    @Test("counts that cannot distinguish speakers yield no constraint")
    func lowCounts() {
        #expect(DiarizationSpeakerBounds.fromAttendeeCount(0) == nil)
        #expect(DiarizationSpeakerBounds.fromAttendeeCount(1) == nil)
    }

    @Test("a small meeting maps to a loose ceiling with min 1")
    func smallMeeting() {
        let bounds = DiarizationSpeakerBounds.fromAttendeeCount(3)
        #expect(bounds == DiarizationSpeakerBounds(minSpeakers: 1, maxSpeakers: 3))
    }

    @Test("the maximum equals the attendee count up to the clamp")
    func atClamp() {
        let clamp = DiarizationSpeakerBounds.maxSpeakerClamp
        let bounds = DiarizationSpeakerBounds.fromAttendeeCount(clamp)
        #expect(bounds == DiarizationSpeakerBounds(minSpeakers: 1, maxSpeakers: clamp))
    }

    @Test("a large all-hands invite is clamped, never forced to the invite size")
    func largeInviteClamped() {
        let bounds = DiarizationSpeakerBounds.fromAttendeeCount(50)
        #expect(bounds?.maxSpeakers == DiarizationSpeakerBounds.maxSpeakerClamp)
        #expect(bounds?.minSpeakers == 1)
    }

    @Test("an exact speaker count is never forced (min stays below max for count > 1)")
    func neverExact() {
        // The mapping must never collapse to min == max == count, which would
        // force phantom speakers when invitees are silent or co-located.
        for count in 2...DiarizationSpeakerBounds.maxSpeakerClamp {
            let bounds = DiarizationSpeakerBounds.fromAttendeeCount(count)
            #expect(bounds?.minSpeakers == 1)
            #expect(bounds?.maxSpeakers == count)
        }
    }
}
