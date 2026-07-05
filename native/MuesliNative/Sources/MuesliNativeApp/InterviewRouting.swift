import Foundation
import MuesliCore

/// Decides whether a meeting should be summarized in "interview mode" (two-lens
/// content-vs-conviction read + offer lean + candidate coaching), and resolves the
/// effective template to use for a given generation.
///
/// Two ways a meeting becomes an interview:
///  1. The user explicitly picks the built-in **Interview** template — always wins.
///  2. The meeting is on **Auto** and *looks* like an interview — detected here from the
///     title + transcript cues, conservatively (needs strong evidence), and steered into
///     interview mode for THIS generation only. The stored template stays Auto; detection
///     is runtime routing, not a template change, so re-summarizing stays consistent.
enum InterviewRouting {
    /// True when the id identifies the built-in Interview template.
    static func isInterview(templateID: String) -> Bool {
        templateID.trimmingCharacters(in: .whitespacesAndNewlines) == MeetingTemplates.interviewID
    }

    /// The template to actually summarize with. Explicit Interview passes through; an Auto
    /// meeting that detects as an interview is swapped to the Interview snapshot; everything
    /// else is returned unchanged.
    static func effectiveTemplate(
        requested: MeetingTemplateSnapshot,
        transcript: String,
        meetingTitle: String
    ) -> MeetingTemplateSnapshot {
        if isInterview(templateID: requested.id) {
            return requested
        }
        guard requested.kind == .auto else { return requested }
        guard detect(transcript: transcript, meetingTitle: meetingTitle) else { return requested }
        return interviewSnapshot
    }

    /// Conservative interview detection: fire when the title clearly says so, OR when the
    /// transcript carries at least two DISTINCT interview-shaped cues. Two cues (not one)
    /// keeps a passing "tell me about the project" in a normal meeting from tripping it.
    static func detect(transcript: String, meetingTitle: String) -> Bool {
        if titleSuggestsInterview(meetingTitle) { return true }
        return distinctPhraseHits(in: transcript) >= 2
    }

    // MARK: - Internals

    private static var interviewSnapshot: MeetingTemplateSnapshot {
        MeetingTemplates.resolveDefinition(id: MeetingTemplates.interviewID, customTemplates: []).snapshot
    }

    /// Calendar-style titles are the strongest signal: "… Interview", "Phone Screen",
    /// "Onsite", "Hiring Loop", "Screening call".
    private static func titleSuggestsInterview(_ title: String) -> Bool {
        let t = title.lowercased()
        let markers = ["interview", "phone screen", "phone-screen", "screening",
                       "onsite", "on-site", "hiring loop", "candidate screen"]
        return markers.contains { t.contains($0) }
    }

    /// Distinct interview-question / structure phrases present in the transcript. Grouped so
    /// repeating the same phrase counts once; the caller requires two DIFFERENT groups.
    private static func distinctPhraseHits(in transcript: String) -> Int {
        let t = transcript.lowercased()
        let phraseGroups: [[String]] = [
            ["tell me about yourself", "walk me through your background", "walk me through your resume"],
            ["do you have any questions for", "any questions for me", "questions for us"],
            ["why do you want to work", "why are you interested in this role", "why this company"],
            ["walk me through a time", "tell me about a time", "give me an example of a time"],
            ["what's your experience with", "what is your experience with", "how much experience do you have"],
            ["where do you see yourself", "what are your career goals"],
            ["salary expectation", "compensation expectation", "notice period", "when could you start"],
            ["what's your greatest weakness", "what is your greatest weakness", "your greatest strength"],
            ["this role", "the position", "the candidate"], // role-framing, weak on its own
        ]
        var hits = 0
        for group in phraseGroups where group.contains(where: { t.contains($0) }) {
            hits += 1
        }
        return hits
    }
}
