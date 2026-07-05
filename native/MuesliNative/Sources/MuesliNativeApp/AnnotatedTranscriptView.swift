import SwiftUI
import MuesliCore
import ProsodyKit

/// Annotated Transcript tab: renders the transcript as clean, readable speaker
/// **turns** (contiguous same-speaker utterances grouped together) with a subtle
/// emotion/prosody layer laid over the top instead of a heavy tag-per-line card.
///
/// The emotion layer:
///   * a thin left **gutter bar** per turn, colored by the turn's mean valence
///     (green positive / red negative / faint neutral) for an at-a-glance tone scan;
///   * a per-turn header (speaker + timestamp) with a small delivery chip shown
///     ONLY when the read isn't "Measured" (noise reduction);
///   * sparse inline markers, surfaced only when notable — a "paused N.Ns" divider
///     between turns and an "N fillers" chip when heavy.
///
/// Used only when `ProsodyReport.annotatedSegments` is non-empty; older meetings
/// fall back to the plain `MeetingTranscriptView`. Typography matches
/// `MeetingTranscriptView`; colors reuse `MuesliTheme` for consistency. Long
/// transcripts stay performant via `LazyVStack`.
struct AnnotatedTranscriptView: View {
    let segments: [AnnotatedSegment]

    /// Thresholds (see the feature spec): only surface a marker when it's meaningful.
    private static let pauseThreshold: Double = 0.6      // seconds, between-turn divider
    private static let fillerThreshold: Int = 3          // per-turn "N fillers" chip
    private static let positiveThreshold: Double = 0.25
    private static let negativeThreshold: Double = -0.25

    /// One rendered turn: contiguous same-speaker utterances with aggregated affect.
    private struct Turn: Identifiable {
        let id: Int
        let speaker: String
        let text: String
        let startSeconds: Double
        /// Pause before the turn (first utterance's `pauseBeforeSeconds`).
        let pauseBeforeSeconds: Double
        let fillerCount: Int
        /// Mean valence over the turn's utterances (nils ignored); nil if none scored.
        let valence: Double?
        /// Mean raw audio arousal over the turn's utterances (nils ignored); nil if
        /// no audio. Circumplex activation axis → drives the gutter color intensity.
        let arousal: Double?
        /// True when any utterance in the turn had TEXT valence (cleared the ≥ 4-word
        /// gate). When false the turn's valence is audio-only and low-confidence, so
        /// the gutter renders neutral gray instead of a bold red/green.
        let hasTextValence: Bool
        let deliveryRead: String?
        /// Any utterance in the turn trailed off (quiet at the end).
        let trailOff: Bool
        /// Any utterance in the turn was monotone (flat pitch).
        let flatPitch: Bool
        /// True on the first turn of each contiguous speaker block (speaker differs
        /// from the previous turn). The delivery chip renders only here.
        var isSpeakerBlockStart: Bool = false
    }

    private let turns: [Turn]
    /// Arousal is interpreted RELATIVE to this meeting's turns (the model's absolute
    /// arousal is compressed), so the stripe intensity spreads across the conversation's
    /// own range instead of everything reading the same low value.
    private let arousalLo: Double
    private let arousalHi: Double
    private static let arousalSpreadFloor: Double = 0.03

    init(segments: [AnnotatedSegment]) {
        self.segments = segments
        let grouped = Self.markSpeakerBlockStarts(Self.groupIntoTurns(segments))
        self.turns = grouped
        let arousals = grouped.compactMap { $0.arousal }
        self.arousalLo = arousals.min() ?? 0
        self.arousalHi = arousals.max() ?? 0
    }

    /// Flags the first turn of each contiguous speaker block so the delivery chip
    /// (a per-speaker read) shows once per block instead of on every turn.
    private static func markSpeakerBlockStarts(_ turns: [Turn]) -> [Turn] {
        var out = turns
        var previousSpeaker: String?
        for i in out.indices {
            let differs = previousSpeaker.map {
                $0.localizedCaseInsensitiveCompare(out[i].speaker) != .orderedSame
            } ?? true
            out[i].isSpeakerBlockStart = differs
            previousSpeaker = out[i].speaker
        }
        return out
    }

    /// Groups contiguous same-speaker utterances into turns and aggregates their
    /// annotations: mean valence (ignoring nils),
    /// `pauseBeforeSeconds` = the first utterance's, `fillerCount` = sum.
    private static func groupIntoTurns(_ segments: [AnnotatedSegment]) -> [Turn] {
        var turns: [Turn] = []
        var buffer: [AnnotatedSegment] = []

        func flush() {
            guard let first = buffer.first else { return }
            let valences = buffer.compactMap { $0.valence }
            let meanValence = valences.isEmpty
                ? nil
                : valences.reduce(0, +) / Double(valences.count)
            let arousals = buffer.compactMap { $0.arousal }
            let meanArousal = arousals.isEmpty
                ? nil
                : arousals.reduce(0, +) / Double(arousals.count)
            let text = buffer.map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            turns.append(Turn(
                id: turns.count,
                speaker: first.speaker,
                text: text,
                startSeconds: first.startSeconds,
                pauseBeforeSeconds: first.pauseBeforeSeconds,
                fillerCount: buffer.reduce(0) { $0 + $1.fillerCount },
                valence: meanValence,
                arousal: meanArousal,
                hasTextValence: buffer.contains { $0.hasTextValence },
                deliveryRead: first.deliveryRead,
                trailOff: buffer.contains { $0.trailOff },
                flatPitch: buffer.contains { $0.flatPitch }
            ))
            buffer.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            if let last = buffer.last,
               last.speaker.localizedCaseInsensitiveCompare(segment.speaker) != .orderedSame {
                flush()
            }
            buffer.append(segment)
        }
        flush()
        return turns
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                if turns.isEmpty {
                    Text("No transcript available")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(maxWidth: 860, alignment: .leading)
                        .padding(MuesliTheme.spacing24)
                } else {
                    ForEach(turns) { turn in
                        if turn.pauseBeforeSeconds >= Self.pauseThreshold {
                            pauseDivider(turn.pauseBeforeSeconds)
                        }
                        turnView(turn)
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing24)
            .padding(.vertical, MuesliTheme.spacing16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Turn

    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        // "You" (local mic) sits on the right with the accent bubble; everyone else
        // on the left with the surface bubble — matching the plain chat-bubble transcript.
        let isUser = turn.speaker.localizedCaseInsensitiveCompare("You") == .orderedSame
        HStack(alignment: .bottom, spacing: MuesliTheme.spacing8) {
            if isUser { Spacer(minLength: 80) }

            // Emotion is surfaced as a named circumplex chip (Upbeat/Tense/Content/
            // Subdued) in the marker row — no color stripe.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(turn.speaker)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text(timeLabel(turn.startSeconds))
                        .font(.system(size: 10))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Text(turn.text)
                    .font(.system(size: 14))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                markerRow(turn)
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 8)
            .background(isUser ? MuesliTheme.accent.opacity(0.18) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isUser ? MuesliTheme.accent.opacity(0.25) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(maxWidth: 680, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - Sparse markers

    /// Only rendered when the turn carries something notable — a filler-heavy turn,
    /// trail-off, monotone, or the delivery chip. The neutral case shows nothing
    /// (just the gutter).
    @ViewBuilder
    private func markerRow(_ turn: Turn) -> some View {
        let hasFillers = turn.fillerCount >= Self.fillerThreshold
        // Per-turn emotion label (circumplex quadrant) — the named version of the gutter.
        let mood = moodChip(valence: turn.valence, arousal: turn.arousal,
                            hasTextValence: turn.hasTextValence)
        // Delivery is a per-speaker read → shown once, on the first turn of a block,
        // now grouped at the bottom with the rest of the badges.
        let deliveryBadge = turn.isSpeakerBlockStart ? deliveryChip(turn.deliveryRead) : nil
        if mood != nil || deliveryBadge != nil || hasFillers || turn.trailOff || turn.flatPitch {
            HStack(spacing: 6) {
                if let mood {
                    mood
                }
                if let deliveryBadge {
                    deliveryBadge
                }
                if hasFillers {
                    marker("\(turn.fillerCount) fillers",
                           systemImage: "waveform",
                           color: MuesliTheme.transcribing)
                }
                if turn.trailOff {
                    marker("faded out",
                           systemImage: "arrow.down.right",
                           color: MuesliTheme.textTertiary)
                }
                if turn.flatPitch {
                    marker("monotone",
                           systemImage: "minus",
                           color: MuesliTheme.textTertiary)
                }
            }
            .padding(.top, 2)
        }
    }

    private func marker(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    /// Subtle "paused N.Ns" divider rendered BETWEEN turns.
    private func pauseDivider(_ seconds: Double) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(height: 1)
                .frame(maxWidth: 40)
            Text("paused \(secs(seconds))")
                .font(.system(size: 10))
                .foregroundStyle(MuesliTheme.textTertiary)
            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(height: 1)
                .frame(maxWidth: 40)
        }
        .frame(maxWidth: 680, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Per-turn delivery chip — shown only when NOT "Measured" (reduce noise).
    private func deliveryChip(_ read: String?) -> AnyView? {
        guard let read, !read.isEmpty else { return nil }
        let tint: Color
        let label: String
        if read.contains("Assertive") {
            tint = MuesliTheme.success
            label = "Assertive"
        } else if read.contains("Reserved") || read.contains("Tentative") {
            tint = MuesliTheme.accent   // neutral — a relative read, not a negative verdict
            label = "Reserved"
        } else {
            return nil   // even-paced → no chip.
        }
        return AnyView(
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.15)))
        )
    }

    /// Per-turn emotion label — the named version of the valence gutter, following
    /// Russell's circumplex (1980). Text-confident, non-neutral valence names the hue
    /// (positive/negative) and relative arousal splits the energy → Upbeat / Tense /
    /// Content / Subdued. When arousal can't be ranked (absent, or a flat meeting) the
    /// energy qualifier is dropped rather than guessed → plain Positive / Negative.
    /// Nil for neutral or low-confidence (audio-only) turns — same as the neutral gutter.
    private func moodChip(valence: Double?, arousal: Double?, hasTextValence: Bool) -> AnyView? {
        guard hasTextValence, let valence else { return nil }
        let positive: Bool
        if valence > Self.positiveThreshold { positive = true }
        else if valence < Self.negativeThreshold { positive = false }
        else { return nil }

        let tint = positive ? MuesliTheme.success : MuesliTheme.recording
        let label: String
        if let rel = relativeArousal(arousal) {
            let high = rel >= 0.5
            label = positive ? (high ? "Upbeat" : "Content")
                             : (high ? "Tense" : "Subdued")
        } else {
            label = positive ? "Positive" : "Negative"
        }
        return AnyView(
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.15)))
        )
    }

    /// This turn's arousal as a fraction of the meeting's arousal range, in [0,1].
    /// Relative because the emotion model compresses absolute arousal, so only
    /// within-meeting ranking is meaningful. Nil when arousal is absent or the meeting
    /// has no spread to rank against.
    private func relativeArousal(_ arousal: Double?) -> Double? {
        guard let a = arousal, (arousalHi - arousalLo) > Self.arousalSpreadFloor else { return nil }
        return min(1, max(0, (a - arousalLo) / (arousalHi - arousalLo)))
    }

    // MARK: - Colors / formatting

    /// Relative offset from meeting start, `m:ss`.
    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func secs(_ x: Double) -> String {
        x >= 10 ? String(format: "%.0fs", x) : String(format: "%.1fs", x)
    }
}
