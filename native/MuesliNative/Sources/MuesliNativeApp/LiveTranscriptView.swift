// Purpose: Scrolling live transcript view with auto-scroll during active meetings
// Created: 2026-05-22

import AppKit
import SwiftUI

enum LiveTranscriptCopyContent {
    static func text(transcript: String, partialYou: String, partialOthers: String) -> String {
        var sections: [String] = []
        let committed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !committed.isEmpty {
            sections.append(committed)
        }
        let others = partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !others.isEmpty {
            sections.append("Others: \(others)")
        }
        let you = partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
        if !you.isEmpty {
            sections.append("You: \(you)")
        }
        return sections.joined(separator: "\n")
    }
}

private struct LiveTranscriptGroup: Identifiable {
    // Stable ID: sequential index of the group in arrival order.
    // Using a deterministic Int instead of UUID prevents SwiftUI from treating
    // every group as removed+reinserted on each transcript update.
    let id: Int
    let speaker: String?
    let isUser: Bool
    let lines: [String]
    let timestamp: String?
}

struct LiveTranscriptBubble: View {
    let speaker: String?
    let timestamp: String?
    let lines: [String]
    let isUser: Bool
    let isPartial: Bool
    var onOpen: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 40) }
            if isUser { copyButton }
            VStack(alignment: .leading, spacing: 2) {
                if let speaker {
                    Text(speaker + (timestamp.map { "  \($0)" } ?? ""))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 13))
                        .italic(isPartial)
                        .foregroundStyle(isPartial ? MuesliTheme.textSecondary : MuesliTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        isPartial ? MuesliTheme.surfaceBorder : committedBorder,
                        style: StrokeStyle(lineWidth: 1, dash: isPartial ? [4, 3] : [])
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            if !isUser { copyButton }
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { isHovered = $0 }
    }

    private var copyButton: some View {
        Button(action: copyMessage) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(didCopy ? MuesliTheme.success : MuesliTheme.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy message")
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
    }

    private func copyMessage() {
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }

    private var bubbleBackground: Color {
        if isPartial {
            return isUser ? MuesliTheme.accent.opacity(0.06) : MuesliTheme.surfacePrimary.opacity(0.5)
        }
        return isUser ? MuesliTheme.accent.opacity(0.15) : MuesliTheme.surfacePrimary
    }

    private var committedBorder: Color {
        isUser ? MuesliTheme.accent.opacity(0.2) : MuesliTheme.surfaceBorder
    }
}

struct LiveTranscriptView: View {
    let transcript: String
    /// Provisional streaming tails (issue #99): rendered as dimmed bubbles after
    /// the committed captions, outside the incremental-parse invariant — they
    /// never enter `transcript`, so `parsedLength` stays valid.
    var partialYou: String = ""
    var partialOthers: String = ""
    @State private var groups: [LiveTranscriptGroup] = []
    // Tracks how many characters of transcript have been parsed into groups.
    // On each onChange we only parse the new suffix, keeping updates O(k)
    // where k = lines in the new chunk rather than O(n) for the full history.
    @State private var parsedLength: Int = 0
    @State private var didCopy = false

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if groups.isEmpty && trimmedPartialYou.isEmpty && trimmedPartialOthers.isEmpty {
                            Text("Waiting for speech…")
                                .font(MuesliTheme.body())
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .padding(MuesliTheme.spacing16)
                        } else {
                            ForEach(groups) { group in
                                liveBubble(for: group)
                            }
                            if !trimmedPartialOthers.isEmpty {
                                partialBubble(text: trimmedPartialOthers, speaker: "Others", isUser: false)
                            }
                            if !trimmedPartialYou.isEmpty {
                                partialBubble(text: trimmedPartialYou, speaker: "You", isUser: true)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("liveTranscriptBottom")
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, MuesliTheme.spacing16)
                    .padding(.top, 44)
                    .padding(.bottom, MuesliTheme.spacing8)
                }
                .onChange(of: transcript) { _, newTranscript in
                    mergeNewContent(from: newTranscript)
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                        }
                    }
                }
                // Partials update every engine chunk; scrolling on each growth
                // would yank a user who scrolled up back to the bottom every few
                // seconds. Scroll only when a tail appears (empty → non-empty);
                // committed captions keep their existing scroll behavior.
                .onChange(of: partialYou) { old, new in
                    if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: partialOthers) { old, new in
                    if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        scrollToBottom(proxy)
                    }
                }
                .onAppear {
                    // @State is freshly initialized on each tab switch, so this
                    // catches up with any chunks that arrived on another tab.
                    mergeNewContent(from: transcript)
                    DispatchQueue.main.async {
                        proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                    }
                }
            }

            Button(action: copyTranscript) {
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(didCopy ? MuesliTheme.success : MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .frame(height: 30)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)
            .padding(.top, MuesliTheme.spacing8)
            .padding(.trailing, MuesliTheme.spacing16)
        }
    }

    private func copyTranscript() {
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }

    private var trimmedPartialYou: String {
        partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPartialOthers: String {
        partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
            }
        }
    }

    private func mergeNewContent(from newTranscript: String) {
        if newTranscript.count < parsedLength {
            groups = []
            parsedLength = 0
        }
        guard newTranscript.count > parsedLength else {
            return
        }
        let startIndex = newTranscript.index(newTranscript.startIndex, offsetBy: parsedLength)
        parsedLength = newTranscript.count

        let newMessages = TranscriptChatMessage.messages(from: String(newTranscript[startIndex...]))
        for msg in newMessages {
            if let last = groups.last, last.speaker == msg.speaker {
                groups[groups.count - 1] = LiveTranscriptGroup(
                    id: last.id,
                    speaker: last.speaker,
                    isUser: last.isUser,
                    lines: last.lines + [msg.text],
                    timestamp: last.timestamp
                )
            } else {
                groups.append(LiveTranscriptGroup(
                    id: groups.count,
                    speaker: msg.speaker,
                    isUser: msg.isUser,
                    lines: [msg.text],
                    timestamp: msg.timestamp
                ))
            }
        }
    }

    /// Provisional streaming tail: dimmed italic text with a dashed border so
    /// it visibly reads as "still being spoken" until the committed caption
    /// replaces it.
    @ViewBuilder
    private func partialBubble(text: String, speaker: String, isUser: Bool) -> some View {
        LiveTranscriptBubble(
            speaker: speaker,
            timestamp: nil,
            lines: [text],
            isUser: isUser,
            isPartial: true
        )
    }

    @ViewBuilder
    private func liveBubble(for group: LiveTranscriptGroup) -> some View {
        LiveTranscriptBubble(
            speaker: group.speaker,
            timestamp: group.timestamp,
            lines: group.lines,
            isUser: group.isUser,
            isPartial: false
        )
    }
}
