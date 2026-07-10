import FluidAudio
import Foundation
import MuesliCore

enum TranscriptFormatter {
    /// Merge mic (local) and system (remote) segments into a labeled transcript,
    /// with optional per-channel speaker diarization.
    ///
    /// Both channels are diarized independently and never share raw speaker IDs.
    /// Labels are assigned in a single pass over the time-sorted stream, so numbers
    /// are always contiguous: the first *local* speaker to appear is `You`; every
    /// other distinct voice — additional co-located locals and all remote speakers —
    /// becomes `Speaker N` in order of first appearance.
    ///
    /// A solo-guard protects the common case: mic diarization is only applied when it
    /// confidently found at least two local speakers. With one (or none), every mic
    /// segment stays `You`, byte-identical to the pre-diarization behavior.
    ///
    /// Limitation: `You` is the *earliest-speaking* local voice, not necessarily the
    /// device owner. Without voice enrollment we cannot tell co-located people apart,
    /// so in a shared room whoever speaks first is labeled `You`. The live transcript
    /// always labels local audio `You`; only this final pass can split it into
    /// `Speaker N`, so a person shown as `You` live may become `Speaker N` here.
    static func merge(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        micDiarizationSegments: [TimedSpeakerSegment]? = nil,
        diarizationSegments: [TimedSpeakerSegment]? = nil,
        meetingStart: Date
    ) -> String {
        // Solo-guard: only split the mic channel when diarization found >= 2 locals.
        let useMicDiarization = Set((micDiarizationSegments ?? []).map(\.speakerId)).count >= 2

        // Resolve each segment to a stable key: a channel-namespaced raw speaker id
        // when diarized, otherwise a fixed label. Mic segments that match no
        // diarization fall back to "You" — never "Others", which is remote-only.
        enum SpeakerKey: Hashable {
            case fixed(String)
            case speaker(String)
        }
        func micKey(for segment: SpeechSegment) -> SpeakerKey {
            guard useMicDiarization, let micDiarizationSegments,
                  let rawId = findSpeakerRawId(for: segment, in: micDiarizationSegments)
            else { return .fixed("You") }
            return .speaker("mic:\(rawId)")
        }
        func systemKey(for segment: SpeechSegment) -> SpeakerKey {
            guard let diarizationSegments, !diarizationSegments.isEmpty,
                  let rawId = findSpeakerRawId(for: segment, in: diarizationSegments)
            else { return .fixed("Others") }
            return .speaker("sys:\(rawId)")
        }

        let keyed: [(segment: SpeechSegment, key: SpeakerKey)] =
            micSegments.map { ($0, micKey(for: $0)) }
            + systemSegments.map { ($0, systemKey(for: $0)) }
        let sortedKeyed = keyed.sorted { $0.segment.start < $1.segment.start }

        // The earliest local speaker is "You"; every other distinct voice gets a
        // "Speaker N" assigned lazily in first-appearance order, so there are no gaps.
        let youKey: SpeakerKey? = useMicDiarization
            ? micDiarizationSegments?
                .min(by: { $0.startTimeSeconds < $1.startTimeSeconds })
                .map { SpeakerKey.speaker("mic:\($0.speakerId)") }
            : nil
        var labelForKey: [SpeakerKey: String] = [:]
        var nextSpeakerNumber = 1
        func label(for key: SpeakerKey) -> String {
            switch key {
            case .fixed(let fixedLabel):
                return fixedLabel
            case .speaker:
                if key == youKey { return "You" }
                if let existing = labelForKey[key] { return existing }
                let assigned = "Speaker \(nextSpeakerNumber)"
                nextSpeakerNumber += 1
                labelForKey[key] = assigned
                return assigned
            }
        }

        let tagged = sortedKeyed.map { TaggedSegment(segment: $0.segment, speaker: label(for: $0.key)) }

        // Consolidate consecutive segments from the same speaker into single lines
        let consolidated = consolidate(tagged)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        return consolidated.map { taggedSegment in
            let timestamp = meetingStart.addingTimeInterval(taggedSegment.segment.start)
            let text = taggedSegment.segment.text.trimmingCharacters(in: .whitespaces)
            return "[\(formatter.string(from: timestamp))] \(taggedSegment.speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// Merge consecutive segments from the same speaker into single entries,
    /// but only when they're temporally close (within 2s). This prevents
    /// token-level fragmentation while preserving chronological ordering —
    /// segments from the same speaker that are far apart in time stay separate
    /// so they interleave correctly with other speakers.
    private static let consolidationGapThreshold: TimeInterval = 2.0

    private static func consolidate(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TaggedSegment] = []
        var currentSpeaker = segments[0].speaker
        var currentStart = segments[0].segment.start
        var currentEnd = segments[0].segment.end
        var currentText = segments[0].segment.text

        for seg in segments.dropFirst() {
            let gap = max(0, seg.segment.start - currentEnd)
            if seg.speaker == currentSpeaker && gap <= consolidationGapThreshold {
                // Same speaker, temporally close — accumulate text
                currentText = appendText(currentText, seg.segment.text, gap: gap)
                currentEnd = max(currentEnd, seg.segment.end)
            } else {
                // Different speaker or too far apart — emit and start new segment
                result.append(TaggedSegment(
                    segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
                    speaker: currentSpeaker
                ))
                currentSpeaker = seg.speaker
                currentStart = seg.segment.start
                currentEnd = seg.segment.end
                currentText = seg.segment.text
            }
        }
        // Emit last segment
        result.append(TaggedSegment(
            segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
            speaker: currentSpeaker
        ))

        return result
    }

    /// Best-matching raw diarization speaker id for an ASR segment, by time overlap,
    /// falling back to the nearest speaker within 2s. Returns nil when nothing matches
    /// (the caller decides the channel-appropriate fallback label).
    private static func findSpeakerRawId(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment]
    ) -> String? {
        let distinctSpeakers = Set(diarizationSegments.map(\.speakerId))
        if distinctSpeakers.count == 1 {
            return distinctSpeakers.first
        }

        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1)) // ensure non-zero duration

        var bestOverlap: Float = 0
        var bestSpeakerId: String?

        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerId = diarSeg.speakerId
            }
        }

        if let bestSpeakerId, bestOverlap > 0 {
            return bestSpeakerId
        }

        return nearestSpeaker(for: segment, in: diarizationSegments, maxGapSeconds: 2.0)
    }


    private static func nearestSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        maxGapSeconds: Float
    ) -> String? {
        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1))
        let segMidpoint = (segStart + segEnd) / 2

        let nearest = diarizationSegments.min { lhs, rhs in
            temporalGap(between: segMidpoint, and: lhs) < temporalGap(between: segMidpoint, and: rhs)
        }

        guard let nearest else { return nil }
        return temporalGap(between: segMidpoint, and: nearest) <= maxGapSeconds ? nearest.speakerId : nil
    }

    private static func temporalGap(
        between point: Float,
        and diarizationSegment: TimedSpeakerSegment
    ) -> Float {
        if point < diarizationSegment.startTimeSeconds {
            return diarizationSegment.startTimeSeconds - point
        }
        if point > diarizationSegment.endTimeSeconds {
            return point - diarizationSegment.endTimeSeconds
        }
        return 0
    }

    private static func appendText(_ lhs: String, _ rhs: String, gap: TimeInterval) -> String {
        if shouldConcatenateDirectly(lhs, rhs, gap: gap) {
            return lhs + rhs
        }
        return joinText(lhs, rhs)
    }

    private static func shouldConcatenateDirectly(_ lhs: String, _ rhs: String, gap: TimeInterval) -> Bool {
        guard gap <= 0.35 else { return false }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard !rhs.contains(where: \.isWhitespace) else { return false }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else { return false }
        guard !lhsLast.isWhitespace, !rhsFirst.isWhitespace, !rhsFirst.isPunctuation else { return false }

        let lhsLastToken = lhs.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? lhs
        guard !lhsLastToken.contains(where: \.isWhitespace) else { return false }

        let lhsVisibleLength = visibleLength(of: lhsLastToken)
        let rhsVisibleLength = visibleLength(of: rhs)
        return lhsVisibleLength + rhsVisibleLength <= 8
    }

    private static func joinText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return lhs + rhs
        }

        if lhsLast.isWhitespace || rhsFirst.isWhitespace || rhsFirst.isPunctuation {
            return lhs + rhs
        }

        if lhsLast.isPunctuation {
            return lhs + " " + rhs
        }

        return lhs + " " + rhs
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }

}

private struct TaggedSegment {
    let segment: SpeechSegment
    let speaker: String
}
