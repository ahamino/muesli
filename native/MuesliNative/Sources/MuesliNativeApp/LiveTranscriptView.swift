// Purpose: Scrolling live transcript view with auto-scroll during active meetings
// Created: 2026-05-22

import SwiftUI

struct LiveTranscriptView: View {
    let transcript: String
    @State private var messages: [TranscriptChatMessage] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    if messages.isEmpty {
                        Text("Waiting for speech…")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(maxWidth: 860, alignment: .leading)
                            .padding(MuesliTheme.spacing24)
                    } else {
                        ForEach(messages) { message in
                            TranscriptChatBubble(message: message)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("liveTranscriptBottom")
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, MuesliTheme.spacing24)
                .padding(.vertical, MuesliTheme.spacing16)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: transcript) { _, newTranscript in
                messages = TranscriptChatMessage.messages(from: newTranscript)
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                    }
                }
            }
            .onAppear {
                messages = TranscriptChatMessage.messages(from: transcript)
            }
        }
    }
}
