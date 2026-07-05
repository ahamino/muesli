import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("InterviewRouting")
struct InterviewRoutingTests {
    private var auto: MeetingTemplateSnapshot { MeetingTemplates.auto.snapshot }
    private var interview: MeetingTemplateSnapshot {
        MeetingTemplates.resolveDefinition(id: MeetingTemplates.interviewID, customTemplates: []).snapshot
    }
    private var oneToOne: MeetingTemplateSnapshot {
        MeetingTemplates.resolveDefinition(id: "one-to-one", customTemplates: []).snapshot
    }

    // MARK: - isInterview

    @Test("isInterview recognizes the built-in interview template id")
    func recognizesInterviewID() {
        #expect(InterviewRouting.isInterview(templateID: MeetingTemplates.interviewID))
        #expect(InterviewRouting.isInterview(templateID: " interview "))
        #expect(!InterviewRouting.isInterview(templateID: "auto"))
        #expect(!InterviewRouting.isInterview(templateID: "one-to-one"))
    }

    // MARK: - detection

    @Test("detects an interview from a clear calendar-style title")
    func detectsFromTitle() {
        #expect(InterviewRouting.detect(transcript: "hi how are you", meetingTitle: "Acme — Backend Interview"))
        #expect(InterviewRouting.detect(transcript: "", meetingTitle: "Phone Screen: Data Eng"))
        #expect(InterviewRouting.detect(transcript: "", meetingTitle: "Candidate Onsite Loop"))
    }

    @Test("detects an interview from two distinct transcript cues")
    func detectsFromTwoCues() {
        let transcript = """
        Interviewer: Thanks for joining. To start, tell me about yourself and your background.
        Candidate: Sure, I have been an engineer for eight years.
        Interviewer: Great. And why do you want to work here specifically?
        Candidate: I admire the product.
        Interviewer: Makes sense. Do you have any questions for me before we wrap?
        """
        #expect(InterviewRouting.detect(transcript: transcript, meetingTitle: "Weekly sync"))
    }

    @Test("does not fire on a normal meeting with a single passing cue")
    func doesNotFireOnSingleCue() {
        // "this role" appears (weak cue) but nothing else — must stay below the 2-cue bar.
        let transcript = """
        Okay so for this role on the migration we still need to size the work.
        Priya, can you take the schema piece? Let us aim to land it by Friday.
        """
        #expect(!InterviewRouting.detect(transcript: transcript, meetingTitle: "Sprint planning"))
    }

    @Test("does not fire on an empty transcript with a neutral title")
    func doesNotFireOnEmpty() {
        #expect(!InterviewRouting.detect(transcript: "", meetingTitle: "Team catch-up"))
    }

    // MARK: - effectiveTemplate

    @Test("explicit interview template always passes through")
    func explicitInterviewPassesThrough() {
        let out = InterviewRouting.effectiveTemplate(
            requested: interview, transcript: "nothing interview-y", meetingTitle: "Random"
        )
        #expect(out.id == MeetingTemplates.interviewID)
    }

    @Test("auto meeting detected as interview is swapped to the interview snapshot")
    func autoDetectedSwapsToInterview() {
        let out = InterviewRouting.effectiveTemplate(
            requested: auto, transcript: "", meetingTitle: "Backend Interview — Loop 2"
        )
        #expect(out.id == MeetingTemplates.interviewID)
        #expect(out.prompt.contains("Interviewer Conviction"))
    }

    @Test("auto meeting that is not an interview stays auto")
    func autoNonInterviewStaysAuto() {
        let out = InterviewRouting.effectiveTemplate(
            requested: auto, transcript: "quarterly planning discussion", meetingTitle: "Q3 Planning"
        )
        #expect(out.id == MeetingTemplates.autoID)
    }

    @Test("a non-auto, non-interview template is never overridden by detection")
    func explicitNonInterviewNotOverridden() {
        // Even with an interview-looking title, an explicitly-picked template wins.
        let out = InterviewRouting.effectiveTemplate(
            requested: oneToOne, transcript: "tell me about yourself", meetingTitle: "Interview"
        )
        #expect(out.id == "one-to-one")
    }
}
