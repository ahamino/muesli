import SwiftUI
import MuesliCore
import ProsodyKit

/// Visual "Delivery & Affect" panel for a completed meeting: talk-share, per-speaker
/// delivery bars, and (when the emotion model ran) diverging voice + text valence
/// bars plus a grounded heat/tension read. Renders from the persisted `ProsodyReport`.
struct MeetingProsodyView: View {
    let report: ProsodyReport?

    private static let palette: [Color] = [
        MuesliTheme.accent,
        Color(hex: 0x34D399), // green
        Color(hex: 0xF59E0B), // amber
        Color(hex: 0xA78BFA), // purple
        Color(hex: 0x22D3EE), // cyan
        Color(hex: 0xF472B6)  // pink
    ]

    private func color(for speaker: String, in order: [String]) -> Color {
        let idx = order.firstIndex(of: speaker) ?? 0
        return Self.palette[idx % Self.palette.count]
    }

    var body: some View {
        Group {
            if let report, !report.speakers.isEmpty {
                content(report)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No delivery & affect data for this meeting")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textSecondary)
            Text("Enable “Prosody & Affect” in Models → Experimental, then record or import a meeting to see per-speaker delivery, tone, and dynamics here.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func content(_ report: ProsodyReport) -> some View {
        // Full order (incl. "Others") drives palette colors and the talk-share bar.
        let order = report.speakers.map(\.speaker)
        // Per-speaker delivery/affect cards drop the unassigned "Others" bucket when
        // a named speaker exists (it's a diarization artifact, not a participant); it
        // stays in the dynamics talk-share above. Mono "Others" meetings keep it.
        let speakerCards = ProsodyAnalyzer.hasNamedSpeakers(order)
            ? report.speakers.filter { !ProsodyAnalyzer.isUnassignedSpeaker($0.speaker) }
            : report.speakers
        let affectBySpeaker = Dictionary(
            (report.affect?.speakers ?? []).map { ($0.speaker, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        // Arousal from this model is compressed into a low band, so absolute "calm/animated"
        // labels are meaningless (everyone reads "calm"). Interpret arousal RELATIVE to the
        // other speakers in this meeting instead — that's what "within-meeting" should mean.
        let arousal = ArousalContext((report.affect?.speakers ?? []).compactMap { $0.meanArousal })
        // Grounded eGeMAPS loudness / vocal-effort, positioned RELATIVE within the
        // meeting (absolute eGeMAPS values aren't cross-recording comparable).
        let egemaps = EGeMAPSContext(
            loudness: RelativeScale(speakerCards.compactMap { $0.egemaps?.loudnessMean }),
            effort: RelativeScale(speakerCards.compactMap { $0.egemaps?.alphaRatioVMean })
        )
        let tension = tensionSummary(report)
        return ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                roomReadCard(report.dynamics, tension: tension, order: order)
                if !speakerCards.isEmpty {
                    deliveryMatrix(speakerCards, order: order, arousal: arousal,
                                   egemaps: egemaps, affect: affectBySpeaker)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Room read (airtime + turn-taking + tension, one panel)

    /// One meeting-level summary panel: the talk-share (turn-taking) bar, a KPI strip of
    /// turn-taking metrics, and — when there's heat — the grounded tension read with its
    /// drivers. Merges what used to be two stacked cards.
    private func roomReadCard(_ d: ConversationDynamics, tension t: TensionSummary?, order: [String]) -> some View {
        card {
            // Header.
            HStack(spacing: 6) {
                Image(systemName: t != nil ? "flame.fill" : "person.2.wave.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t?.tint ?? MuesliTheme.accent)
                Text("Room read").font(MuesliTheme.headline()).foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
            }

            // Tension as a heat bar (Calm → High) with a marker at this meeting's level —
            // the scale gives the level its meaning, unlike a bare "High" label.
            if let t {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    rowMetricLabel("Tension")
                    TensionHeatBar(fraction: tensionFraction(t.level), levelWord: t.level, tint: t.tint)
                }
            }

            // Airtime — talk-share (turn-taking) bar, labeled to line up with Tension.
            let shares = order.map { ($0, d.talkShare[$0] ?? 0, color(for: $0, in: order)) }
            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                rowMetricLabel("Airtime")
                StackedShareBar(segments: shares)
                    .frame(height: 18)
            }
            FlexibleWrap(spacing: MuesliTheme.spacing12) {
                ForEach(order, id: \.self) { name in
                    HStack(spacing: 6) {
                        Circle().fill(color(for: name, in: order)).frame(width: 8, height: 8)
                        Text("\(name) · \(pct(d.talkShare[name] ?? 0))")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                }
            }
            .padding(.leading, Self.rowLabelWidth + MuesliTheme.spacing12)

            // KPI strip — turn-taking metrics as number-over-label, not chips.
            FlexibleWrap(spacing: MuesliTheme.spacing24) {
                kpi("\(d.turnCount)", "turns")
                kpi(String(format: "%.1f", d.switchesPerMin), "switches/min")
                kpi("\(d.backchannelCount)", "backchannels")
                if d.monologueFrac > 0.001 {
                    kpi(pct(d.monologueFrac), "in monologue")
                }
                if let sp = d.longestMonologueSpeaker, d.longestMonologueSeconds > 1 {
                    kpi(secs(d.longestMonologueSeconds), "longest · \(sp)")
                }
            }
            .padding(.top, 2)

            // Tension drivers — only when there's heat to explain.
            if let t {
                Divider().overlay(MuesliTheme.surfaceBorder)
                VStack(alignment: .leading, spacing: 4) {
                    if t.elevatedEffort, let who = t.effortSpeaker {
                        tensionRow("waveform.path",
                                   "elevated vocal effort — \(who) sounded more pressed than the others")
                    }
                    if t.interruptions > 0 || t.overlapSeconds > 0 {
                        tensionRow("arrow.left.arrow.right",
                                   "\(t.interruptions) interruptions\(interruptionBreakdown(d, order: order)) · \(secs(t.overlapSeconds)) talking over each other")
                    }
                    if t.highArousal {
                        tensionRow("waveform.badge.exclamationmark",
                                   "high activation — voices ran more animated than the room")
                    }
                }
                Text("Tension blends grounded heat signals — vocal effort, interruptions/overlap, and activation — read relative to this meeting.")
                    .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shared width for the "Tension" / "Airtime" row labels so their bars line up.
    private static let rowLabelWidth: CGFloat = 56

    private func rowMetricLabel(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            .frame(width: Self.rowLabelWidth, alignment: .leading)
    }

    /// Marker position on the Calm→High heat bar for a discrete tension level.
    private func tensionFraction(_ level: String) -> Double {
        switch level {
        case ProsodyTension.Level.high.rawValue: return 0.84
        case ProsodyTension.Level.elevated.rawValue: return 0.5
        default: return 0.16   // Calm
        }
    }

    /// A single KPI: big value over a small label.
    private func kpi(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(MuesliTheme.textPrimary)
            Text(label).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
        }
    }

    // MARK: - Tension

    private struct TensionSummary {
        let level: String          // "High" / "Elevated" / "Calm"
        let tint: Color
        let overlapSeconds: Double
        let interruptions: Int
        // Grounded eGeMAPS vocal effort — a SUPPORTING signal (relative, not absolute):
        // set when the highest-effort speaker's alpha ratio sits clearly above the
        // meeting mean. nil `effortSpeaker` when not elevated.
        let elevatedEffort: Bool
        let effortSpeaker: String?
        // High activation — the top speaker's mean arousal sits clearly above the
        // meeting mean (relative, within-meeting; absolute arousal is compressed).
        let highArousal: Bool
    }

    /// Meeting-level "heat/tension" read. The grounded computation is shared with the
    /// notes-prompt renderer (`ProsodyTension`); the view only layers tint colors on top
    /// of the computed `level` so the card and the prompt never drift.
    private func tensionSummary(_ report: ProsodyReport) -> TensionSummary? {
        guard let t = ProsodyTension.compute(report) else { return nil }
        let tint: Color
        switch t.level {
        case .high: tint = MuesliTheme.recording
        case .elevated: tint = MuesliTheme.transcribing
        case .calm: tint = MuesliTheme.success
        }
        return TensionSummary(level: t.level.rawValue, tint: tint,
                              overlapSeconds: t.overlapSeconds, interruptions: t.interruptions,
                              elevatedEffort: t.elevatedEffort, effortSpeaker: t.effortSpeaker,
                              highArousal: t.highArousal)
    }

    /// "(Speaker 1 ×5 · Speaker 2 ×3)" — who did the interrupting. Empty when there's no
    /// per-speaker breakdown (older reports / imports).
    private func interruptionBreakdown(_ d: ConversationDynamics, order: [String]) -> String {
        guard let by = d.interruptionsBySpeaker else { return "" }
        let parts = order
            .filter { (by[$0] ?? 0) > 0 && !ProsodyAnalyzer.isUnassignedSpeaker($0) }
            .map { "\($0) ×\(by[$0] ?? 0)" }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
    }

    private func tensionRow(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).foregroundStyle(MuesliTheme.textSecondary)
            Text(text).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Delivery matrix (speakers compared by dimension)

    /// Column width for each metric cell's mini-bar, so bars line up across speakers and
    /// the comparison reads left-to-right.
    private static let cellBarWidth: CGFloat = 132

    /// The per-speaker content as a comparison matrix: one row per metric, one column
    /// per speaker, with the CONCRETE number in every cell plus a within-meeting relative
    /// mini-bar. This makes the "relative to the room" framing legible at a glance instead
    /// of a wall of stacked per-speaker cards.
    private func deliveryMatrix(_ speakers: [SpeakerProsody], order: [String],
                                arousal: ArousalContext, egemaps: EGeMAPSContext,
                                affect: [String: SpeakerAffect]) -> some View {
        // Which optional rows to render — only when at least one speaker carries the data.
        let anyPitch = speakers.contains { $0.pitchCV != nil }
        let anyLoud = speakers.contains { $0.egemaps?.loudnessMean != nil }
        let anyEffort = speakers.contains { $0.egemaps?.alphaRatioVMean != nil }
        let anyPause = speakers.contains { $0.longestPause > 0.5 }
        let anyVoice = speakers.contains { affect[$0.speaker]?.meanAudioValence != nil }
        let anyText = speakers.contains { affect[$0.speaker]?.meanTextValence != nil }
        let anyArousal = speakers.contains { affect[$0.speaker]?.meanArousal != nil }
        let notes = speakers.filter { !$0.qualitativeNotes.isEmpty }

        return card {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sectionTitle("Delivery", systemImage: "gauge.with.dots.needle.33percent")
                Text("· relative to the room")
                    .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: MuesliTheme.spacing20,
                     verticalSpacing: MuesliTheme.spacing12) {
                    // Header — speaker names.
                    GridRow {
                        rowLabel("")
                        ForEach(speakers, id: \.speaker) { sp in speakerHeaderCell(sp, order: order) }
                    }
                    // Style — grounded delivery labels (badges).
                    GridRow {
                        rowLabel("Style")
                        ForEach(speakers, id: \.speaker) { sp in styleCell(sp) }
                    }
                    // Pace — absolute wpm with slow/fast reference markers (110 / 170).
                    GridRow {
                        rowLabel("Pace")
                        ForEach(speakers, id: \.speaker) { sp in
                            matrixCell(number: "\(Int(sp.wpm.rounded())) wpm",
                                       fraction: clamp(sp.wpm / 220), tint: MuesliTheme.accent,
                                       markers: [110.0 / 220, 170.0 / 220])
                        }
                    }
                    if anyLoud {
                        GridRow {
                            rowLabel("Loudness")
                            ForEach(speakers, id: \.speaker) { sp in
                                if let loud = sp.egemaps?.loudnessMean {
                                    matrixCell(number: String(format: "%.2f", loud),
                                               fraction: egemaps.loudness.fraction(loud),
                                               tint: MuesliTheme.accent,
                                               note: egemaps.loudness.label(loud, higher: "louder", lower: "quieter", similar: "similar"))
                                } else { emptyCell() }
                            }
                        }
                    }
                    if anyEffort {
                        GridRow {
                            rowLabel("Vocal effort")
                            ForEach(speakers, id: \.speaker) { sp in
                                if let alpha = sp.egemaps?.alphaRatioVMean {
                                    matrixCell(number: String(format: "%.1f dB", alpha),
                                               fraction: egemaps.effort.fraction(alpha),
                                               tint: Color(hex: 0xF59E0B),
                                               note: egemaps.effort.label(alpha, higher: "more effortful", lower: "more relaxed", similar: "similar"))
                                } else { emptyCell() }
                            }
                        }
                    }
                    if anyPitch {
                        GridRow {
                            rowLabel("Pitch variation")
                            ForEach(speakers, id: \.speaker) { sp in
                                if let cv = sp.pitchCV {
                                    matrixCell(number: String(format: "%.2f", cv),
                                               fraction: clamp(cv / 0.5), tint: Color(hex: 0xA78BFA))
                                } else { emptyCell() }
                            }
                        }
                    }
                    // Fillers — absolute per-minute; tinted when above the high-filler cutoff.
                    GridRow {
                        rowLabel("Fillers")
                        ForEach(speakers, id: \.speaker) { sp in
                            matrixCell(number: String(format: "%.1f/min", sp.fillerRatePerMin),
                                       fraction: clamp(sp.fillerRatePerMin / 12),
                                       tint: sp.fillerRatePerMin > ProsodyThresholds.highFillerRatePerMin ? MuesliTheme.transcribing : MuesliTheme.accent)
                        }
                    }
                    if anyPause {
                        GridRow {
                            rowLabel("Longest pause")
                            ForEach(speakers, id: \.speaker) { sp in
                                if sp.longestPause > 0.5 {
                                    matrixCell(number: secs(sp.longestPause),
                                               fraction: clamp(sp.longestPause / 10), tint: MuesliTheme.textTertiary)
                                } else { emptyCell() }
                            }
                        }
                    }
                    if anyArousal {
                        GridRow {
                            rowLabel("Activation")
                            ForEach(speakers, id: \.speaker) { sp in
                                if let ar = affect[sp.speaker]?.meanArousal {
                                    Text(arousal.label(ar))
                                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                                        .gridColumnAlignment(.leading)
                                } else { emptyCell() }
                            }
                        }
                    }
                    if anyVoice {
                        GridRow {
                            rowLabel("Tone · voice")
                            ForEach(speakers, id: \.speaker) { sp in
                                if let voice = affect[sp.speaker]?.meanAudioValence {
                                    let intensity = affect[sp.speaker]?.meanArousal.map { arousal.intensity($0) } ?? 0.6
                                    toneCell(voice, intensity: intensity)
                                } else { emptyCell() }
                            }
                        }
                    }
                    if anyText {
                        GridRow {
                            rowLabel("Tone · words")
                            ForEach(speakers, id: \.speaker) { sp in
                                if let text = affect[sp.speaker]?.meanTextValence {
                                    toneCell(text, intensity: 1.0)
                                } else { emptyCell() }
                            }
                        }
                    }
                }
            }

            if anyVoice || anyText {
                Text("Tone — voice (acoustic valence, intensity = activation) vs. words (text sentiment). Loudness, effort and pitch are shown relative to this meeting.")
                    .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Qualitative notes, folded under the matrix, grouped by speaker.
            if !notes.isEmpty {
                Divider().overlay(MuesliTheme.surfaceBorder)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.speaker) { sp in
                        Text("\(sp.speaker): \(sp.qualitativeNotes.joined(separator: " · "))")
                            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Matrix cells

    /// Left-hand metric label, fixed width so every row's speaker columns start aligned.
    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            .frame(width: 92, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    private func speakerHeaderCell(_ sp: SpeakerProsody, order: [String]) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(for: sp.speaker, in: order)).frame(width: 9, height: 9)
            Text(sp.speaker).font(MuesliTheme.captionMedium()).foregroundStyle(MuesliTheme.textPrimary)
        }
        .frame(width: Self.cellBarWidth, alignment: .leading)
        .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func styleCell(_ sp: SpeakerProsody) -> some View {
        Group {
            if let d = sp.delivery {
                let badges = d.nonNeutralBadges
                VStack(alignment: .leading, spacing: 4) {
                    if badges.isEmpty {
                        axisBadge(DeliveryLabels.neutralAssertiveness)
                    } else {
                        ForEach(badges, id: \.self) { axisBadge($0) }
                    }
                }
            } else {
                // Older reports (no grounded labels) fall back to the prose delivery read.
                deliveryBadge(sp.deliveryRead)
            }
        }
        .frame(width: Self.cellBarWidth, alignment: .leading)
        .gridColumnAlignment(.leading)
    }

    /// Standard cell: the concrete NUMBER on top, a within-meeting relative mini-bar
    /// below, and an optional relative word (e.g. "louder").
    private func matrixCell(number: String, fraction: Double, tint: Color,
                            markers: [Double] = [], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(number).font(MuesliTheme.captionMedium()).foregroundStyle(MuesliTheme.textPrimary)
            MiniBar(fraction: fraction, tint: tint, markers: markers)
                .frame(width: Self.cellBarWidth, height: 6)
            if let note {
                Text(note).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary).lineLimit(1)
            }
        }
        .gridColumnAlignment(.leading)
    }

    /// Tone cell: signed valence number over a small diverging bar (red left / green right).
    private func toneCell(_ value: Double, intensity: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%+.2f", value)).font(MuesliTheme.captionMedium()).foregroundStyle(MuesliTheme.textPrimary)
            DivergingBar(value: value, intensity: intensity)
                .frame(width: Self.cellBarWidth, height: 12)
        }
        .gridColumnAlignment(.leading)
    }

    private func emptyCell() -> some View {
        Text("—").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
            .frame(width: Self.cellBarWidth, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    // MARK: - Small pieces

    /// A single grounded-axis chip, reusing the delivery-chip capsule styling. Tint is
    /// keyed off the label; unrecognized/neutral labels read as muted tertiary.
    private func axisBadge(_ label: String) -> some View {
        let tint: Color
        switch label {
        case DeliveryLabels.assertive, DeliveryLabels.projecting: tint = MuesliTheme.success
        case DeliveryLabels.reserved, DeliveryLabels.relaxed: tint = MuesliTheme.accent
        case DeliveryLabels.expressive: tint = Color(hex: 0xA78BFA)
        case DeliveryLabels.strained: tint = Color(hex: 0xF59E0B)
        default: tint = MuesliTheme.textTertiary   // Monotone / Soft / neutral
        }
        return Text(label)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(tint)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func deliveryBadge(_ read: String) -> some View {
        let isReserved = read.contains("Reserved") || read.contains("Tentative")
        let tint: Color = read.contains("Assertive") ? MuesliTheme.success
            : isReserved ? MuesliTheme.accent
            : MuesliTheme.textTertiary
        let label = read.contains("Assertive") ? "Assertive"
            : isReserved ? "Reserved"
            : "Even-paced"
        return Text(label)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(tint)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(MuesliTheme.accent)
            Text(title).font(MuesliTheme.headline()).foregroundStyle(MuesliTheme.textPrimary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12, content: content)
            .padding(MuesliTheme.spacing16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium).fill(MuesliTheme.backgroundBase))
            .overlay(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium).strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
    }

    // MARK: - Formatting helpers

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
    private func secs(_ x: Double) -> String { x >= 60 ? String(format: "%.1fm", x / 60) : String(format: "%.0fs", x) }
}

/// Interprets a speaker's mean arousal RELATIVE to the other speakers in the same
/// meeting. The audEERING model's absolute arousal is compressed into a narrow low
/// band, so an absolute "calm/animated" cutoff labels everyone "calm"; comparing
/// within the meeting is the only honest read. When speakers are effectively equal
/// (no spread) both the intensity and the label collapse to "similar".
private struct ArousalContext {
    let mean: Double
    let lo: Double
    let hi: Double
    let count: Int

    private static let spreadFloor = 0.03   // below this, speakers are effectively equal
    private static let deltaBand = 0.02     // |a − mean| under this reads as "similar"

    init(_ values: [Double]) {
        count = values.count
        if values.isEmpty {
            mean = 0.35; lo = 0.35; hi = 0.35
        } else {
            mean = values.reduce(0, +) / Double(values.count)
            lo = values.min() ?? 0.35
            hi = values.max() ?? 0.35
        }
    }

    private var hasSpread: Bool { count > 1 && (hi - lo) > Self.spreadFloor }

    /// Fill opacity for the valence bar: relative position in the meeting's arousal
    /// range → [0.4, 0.95]; a flat mid value when there's no meaningful spread.
    func intensity(_ a: Double) -> Double {
        guard hasSpread else { return 0.6 }
        let rel = Swift.min(1, Swift.max(0, (a - lo) / (hi - lo)))
        return 0.4 + 0.55 * rel
    }

    /// Comparative label relative to the meeting's speakers.
    func label(_ a: Double) -> String {
        guard hasSpread else { return "similar activation" }
        let d = a - mean
        if d > Self.deltaBand { return "more animated" }
        if d < -Self.deltaBand { return "more subdued" }
        return "similar activation"
    }
}

/// Meeting-wide relative scales for the grounded eGeMAPS bars, built once from all
/// shown speakers and threaded into each card so a bar means "relative to the others".
private struct EGeMAPSContext {
    let loudness: RelativeScale
    let effort: RelativeScale
}

// MARK: - Bar primitives

/// Tension as a heat bar: a green→amber→red gradient track with a marker at this
/// meeting's level and Calm/High end labels. The scale gives the level its meaning.
private struct TensionHeatBar: View {
    let fraction: Double     // 0 (Calm) … 1 (High)
    let levelWord: String    // "Calm" / "Elevated" / "High"
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * min(1, max(0, fraction))
                ZStack {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [MuesliTheme.success, MuesliTheme.transcribing, MuesliTheme.recording],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                        .position(x: w / 2, y: 15)
                    // Marker tick through the bar.
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3, height: 15)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .position(x: x, y: 15)
                    // Level word above the marker (kept inside the bounds at the extremes).
                    Text(levelWord)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                        .fixedSize()
                        .position(x: min(w - 18, max(18, x)), y: 4)
                }
            }
            .frame(height: 24)
            HStack {
                Text("Calm").font(.system(size: 9)).foregroundStyle(MuesliTheme.textTertiary)
                Spacer()
                Text("High").font(.system(size: 9)).foregroundStyle(MuesliTheme.textTertiary)
            }
        }
    }
}

/// Compact bar (no label) for the delivery matrix cells. `fraction` in 0...1; optional
/// reference markers (0...1) — used by Pace for the slow/fast bands.
private struct MiniBar: View {
    let fraction: Double
    let tint: Color
    var markers: [Double] = []

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MuesliTheme.surfacePrimary)
                Capsule().fill(tint)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    Rectangle()
                        .fill(MuesliTheme.textTertiary.opacity(0.6))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * min(1, max(0, m)))
                }
            }
        }
    }
}

/// Diverging bar centered at zero: negative fills left (red), positive fills right
/// (green). Per Russell's circumplex, `intensity` (0...1, from arousal) scales the
/// fill opacity — the direction/hue is valence, the vividness is activation.
private struct DivergingBar: View {
    let value: Double // -1...1
    var intensity: Double = 1.0 // 0...1 fill opacity (arousal-derived)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let half = w / 2
            let frac = min(1, abs(value))
            let tint = (value < 0 ? MuesliTheme.recording : MuesliTheme.success)
                .opacity(min(1, max(0, intensity)))
            ZStack(alignment: .center) {
                Capsule().fill(MuesliTheme.surfacePrimary)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if value < 0 {
                        Rectangle().fill(tint).frame(width: half * frac)
                    }
                }
                .frame(width: half)
                .offset(x: -half / 2)
                HStack(spacing: 0) {
                    if value >= 0 {
                        Rectangle().fill(tint).frame(width: half * frac)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: half)
                .offset(x: half / 2)
                Rectangle().fill(MuesliTheme.textTertiary).frame(width: 1)
            }
            .clipShape(Capsule())
        }
    }
}

/// Single horizontal bar split into per-speaker segments.
private struct StackedShareBar: View {
    let segments: [(String, Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    seg.2.frame(width: max(0, geo.size.width * seg.1))
                }
                Spacer(minLength: 0)
            }
        }
        .clipShape(Capsule())
    }
}

/// Wraps chips/legend onto multiple lines within the available width (never scrolls off
/// screen). Thin wrapper over `FlowLayout`.
private struct FlexibleWrap<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: spacing) { content() }
    }
}

/// A real flow layout: lays subviews left-to-right, wrapping to a new line when the next
/// subview would overflow the proposed width. Sizes to the wrapped height so the card
/// grows vertically instead of clipping horizontally.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            x += size.width + spacing
            widest = Swift.max(widest, x - spacing)
            rowHeight = Swift.max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, (x - bounds.minX) + size.width > bounds.width {
                x = bounds.minX; y += rowHeight + lineSpacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
    }
}
