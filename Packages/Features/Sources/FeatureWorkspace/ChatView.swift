import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// The Chat tab: questions about this recording, answered from its transcript, notes, summary and files, with sources.
struct ChatView: View {
    let workspace: WorkspaceModel
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false

    private var chat: ChatModel { workspace.chat }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let reason = workspace.chatUnavailableReason() {
                EmptyState(systemImage: "sparkles", title: "Chat is not available", message: LocalizedStringKey(reason))  // stock-chrome: AI glyph
                    .accessibilityIdentifier("chat.unavailable")
            } else {
                conversation
                composer
                Text(workspace.isLive
                     ? "Answered on this Mac from what has been said so far. Check important details at the sources."
                     : "Answered on this Mac from the transcript, notes and files. Check important details at the sources.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText)
                    .padding(.horizontal, DSSpacing.md).padding(.bottom, DSSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DSColor.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.page")
        .confirmationDialog("Clear this conversation?", isPresented: $confirmClear) {
            Button("Clear Conversation", role: .destructive) { Task { await chat.clear() } }
        } message: {
            Text("The questions and answers for this recording are deleted. Your notes and summary are not affected.")
        }
    }

    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            Menu {
                Picker("Answer from", selection: Binding(get: { chat.scope }, set: { chat.scope = $0 })) {
                    Text("Everything (transcript, notes, files)").tag(ChatScope.everything)
                    Text("Summary and notes only").tag(ChatScope.summaryAndNotes)
                }
                .pickerStyle(.inline)
            } label: {
                Label(chat.scope == .everything ? "Sources: Everything" : "Sources: Summary and notes", systemImage: "text.book.closed")  // stock-chrome: sources glyph
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("chat.scope")
            .help("Choose what answers may use")
            Spacer()
            if workspace.isLive, let upTo = chat.answeredUpTo {
                Text("Up to \(clock(upTo)) of the live transcript").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Button("Clear", systemImage: "trash") { confirmClear = true }  // stock-chrome: clear chat
                .labelStyle(.titleAndIcon).buttonStyle(.dsHoverIcon).disabled(chat.messages.isEmpty && !chat.isAnswering)
                .accessibilityIdentifier("chat.clear")
        }
        .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.sm)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    if chat.messages.isEmpty && !chat.isAnswering { starter }
                    ForEach(chat.messages) { message in
                        Bubble(message: message, workspace: workspace).id(message.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
                                removal: .opacity))
                    }
                    if chat.isAnswering { StreamingAnswer(chat: chat, proxy: proxy).id("answering").transition(.opacity) }
                    if let error = chat.errorMessage {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").font(DSTypography.caption).foregroundStyle(DSColor.danger)  // stock-chrome: error glyph
                            Spacer()
                            Button("Dismiss", systemImage: "xmark") { chat.dismissError() }.labelStyle(.iconOnly).buttonStyle(.dsHoverIcon)
                        }
                        .accessibilityIdentifier("chat.error")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .dsAnimation(.settle, value: chat.messages.count)
                .dsAnimation(.glide, value: chat.isAnswering)
                .padding(DSSpacing.md)
            }
            .onChange(of: chat.messages.count) { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { proxy.scrollTo("end") } }
        }
        .accessibilityIdentifier("chat.conversation")
    }

    private var starter: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(workspace.isLive ? "Ask about what has been said so far." : "Ask anything about this recording.")
                .font(DSTypography.headline)
            Text("Answers come from the transcript, your notes and attached files, and say when something is not stated.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            WrapRow {
                ForEach(ChatModel.suggestions(for: workspace.source, hasFiles: !workspace.files.attachments.isEmpty), id: \.self) { suggestion in
                    Button(suggestion) { chat.ask(suggestion) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("chat.suggestion")
                }
            }
        }
        .padding(.vertical, DSSpacing.md)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DSSpacing.sm) {
            @Bindable var chat = chat
            TextField(workspace.isLive ? "Ask about the meeting so far…" : "Ask about this recording…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4).focused($inputFocused)
                .onSubmit { chat.send() }
                .padding(DSSpacing.sm)
                .background(DSColor.paper, in: RoundedRectangle(cornerRadius: DSRadius.medium))
                .accessibilityIdentifier("chat.input")
            Button("Send", systemImage: "arrow.up") { chat.send() }  // stock-chrome: send glyph
                .labelStyle(.iconOnly).dsProminentButton().buttonBorderShape(.circle)
                .disabled(!chat.canSend).keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("chat.send")
        }
        .padding(DSSpacing.md)
    }

    private func clock(_ time: TimeInterval) -> String { NotesModel.timestamp(time).trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
}

private struct Bubble: View {
    let message: ChatMessage
    let workspace: WorkspaceModel

    var body: some View {
        let isUser = message.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: DSSpacing.xs) {
            Text(message.text)
                .font(DSTypography.body).textSelection(.enabled)
                .foregroundStyle(isUser ? DSColor.onAccent : DSColor.primaryText)
                .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.sm)
                .background(isUser ? AnyShapeStyle(DSColor.accent) : AnyShapeStyle(DSColor.paper), in: RoundedRectangle(cornerRadius: DSRadius.medium))
            if !message.sources.isEmpty {
                WrapRow {
                    ForEach(message.sources) { source in
                        Button { workspace.open(source) } label: { Label(source.label, systemImage: Self.symbol(source.kind)) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .help("Go to \(source.label)")
                            .accessibilityLabel("Source \(source.label)")
                            .accessibilityIdentifier("chat.source")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isUser ? "chat.message.user" : "chat.message.assistant")
    }

    static func symbol(_ kind: ChatSource.Kind) -> String {  // stock-chrome: source glyphs
        switch kind {
        case .transcript: "clock"
        case .page: "doc.richtext"
        case .notes, .summary: "note.text"
        }
    }
}

/// Wraps its children onto as many lines as needed.
struct WrapRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        FlowLayout(spacing: DSSpacing.xs) { content() }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}


/// The answer while it streams. It reads the growing text itself, so each token re-evaluates only this bubble, not the whole conversation.
private struct StreamingAnswer: View {
    let chat: ChatModel
    let proxy: ScrollViewProxy

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if chat.partial.isEmpty {
                HStack(spacing: DSSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Reading the transcript…").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            } else {
                Text(chat.partial).font(DSTypography.body).textSelection(.enabled)
            }
            Button("Stop") { chat.stop() }.controlSize(.small).accessibilityIdentifier("chat.stop")
        }
        .padding(DSSpacing.md)
        .background(DSColor.paper, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .accessibilityIdentifier("chat.answering")
        .onChange(of: chat.partial) { proxy.scrollTo("end") }
    }
}
