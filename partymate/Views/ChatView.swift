import SwiftUI
import UIKit

/// One-on-one chat with a match, modeled on iMessage: blue and grey bubbles with tails,
/// "Delivered" / "Read" under your last message, swipe left to see each message's time,
/// and the other person's photo in the header (tap it for their profile).
struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let matchID: UUID

    @State private var draft = ""
    @State private var isReporting = false
    @State private var isShowingProfile = false
    /// How far the conversation is dragged left to reveal message times (0...timeRevealWidth).
    @State private var timeReveal: CGFloat = 0
    @FocusState private var isComposerFocused: Bool

    private let timeRevealWidth: CGFloat = 64

    private var match: Match? { store.match(withID: matchID) }
    private var me: UUID? { store.currentUserID }
    private var other: Profile? {
        guard let match, let me else { return nil }
        return match.otherProfile(for: me)
    }
    private var otherName: String { other?.name ?? "Chat" }
    private var messages: [Message] { store.messages(for: matchID) }
    private var sharedParties: [Party] {
        other.map { store.sharedParties(with: $0.id) } ?? []
    }

    /// The last message you sent that reached the server; "Delivered" or "Read" goes under it.
    private var lastOwnDeliveredID: UUID? {
        messages.last { $0.senderId == me && $0.deliveryState == .delivered }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if messages.isEmpty {
                        matchedIntro
                    } else if let shared = bothGoingText(sharedParties) {
                        // A quiet system note at the top of the conversation, like iMessage.
                        Text(shared)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 32)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        let next = index + 1 < messages.count ? messages[index + 1] : nil

                        if shouldShowTimestamp(for: message, after: previous) {
                            TimestampHeader(date: message.createdAt)
                                .padding(.top, index == 0 ? 4 : 14)
                                .padding(.bottom, 6)
                        }

                        MessageRow(
                            message: message,
                            isFromMe: message.senderId == me,
                            isLastInGroup: next.map {
                                $0.senderId != message.senderId || shouldShowTimestamp(for: $0, after: message)
                            } ?? true,
                            status: status(for: message),
                            timeReveal: timeReveal,
                            timeRevealWidth: timeRevealWidth
                        ) {
                            Task { await store.retry(message) }
                        }
                        .id(message.id)
                    }

                    if store.isOtherTyping(in: matchID) {
                        TypingIndicator()
                            .id("typing")
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .animation(.snappy, value: store.isOtherTyping(in: matchID))
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(timeRevealGesture)
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.isOtherTyping(in: matchID)) { _, typing in
                if typing { scrollToBottom(proxy) }
            }
            .onChange(of: isComposerFocused) { _, focused in
                if focused { scrollToBottom(proxy) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .safeAreaBar(edge: .top) {
            header
                // Pull the header up so the photo lines up with the back and ••• buttons,
                // like iMessage. It's taller than a navigation bar title can be.
                .padding(.top, -50)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SafetyMenu(userName: otherName, showsUnmatch: true) {
                    Task {
                        if await store.unmatch(matchID) { dismiss() }
                    }
                } onBlock: {
                    Task {
                        if let other, await store.block(other.id) { dismiss() }
                    }
                } onReport: {
                    isReporting = true
                }
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: matchID) {
            if let other {
                await store.loadSharedParties(with: [other.id])
            }
            await store.loadMessages(for: matchID)
            await store.markRead(matchID)
            // Runs until this view goes away.
            await store.listenForMessages(in: matchID)
        }
        .sheet(isPresented: $isShowingProfile) {
            if let other {
                ProfilePreviewSheet(profile: other)
            }
        }
        .sheet(isPresented: $isReporting) {
            if let other {
                ReportSheet(userID: other.id, userName: other.name, partyID: match?.partyId)
            }
        }
    }

    /// iMessage-style header: their photo, with their name in a glass pill below. Tap for their profile.
    private var header: some View {
        Button {
            isShowingProfile = true
        } label: {
            VStack(spacing: 4) {
                AvatarView(url: other?.avatarURL, size: 50)
                HStack(spacing: 3) {
                    Text(otherName)
                        .font(.footnote.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
        .accessibilityLabel("\(otherName), view profile")
    }

    /// Shown at the top of a brand-new chat.
    private var matchedIntro: some View {
        VStack(spacing: 10) {
            AvatarView(url: other?.avatarURL, size: 84)
            Text("You matched with \(otherName)")
                .font(.headline)
            if let partyName = match?.party?.name {
                Text("at \(partyName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let shared = bothGoingText(sharedParties) {
                Text(shared)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 2)
            }
            Text("Say hi to start the conversation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Composer

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// iMessage-style composer: a glass capsule with the blue send button inside.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.leading, 16)
                .padding(.vertical, 10)
                .focused($isComposerFocused)
                .onSubmit { send() }
                .onChange(of: draft) { _, text in
                    if !text.isEmpty { store.sendTyping(in: matchID) }
                }

            if canSend {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.blue, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5)
                .padding(.bottom, 5)
                .accessibilityLabel("Send")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minHeight: 40)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.snappy(duration: 0.2), value: canSend)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await store.send(text, in: matchID) }
    }

    // MARK: - Behavior

    /// Drag left to slide the conversation over and show each message's time, like iMessage.
    private var timeRevealGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                timeReveal = min(timeRevealWidth, max(0, -value.translation.width * 0.6))
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.3)) {
                    timeReveal = 0
                }
            }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target: AnyHashable = store.isOtherTyping(in: matchID) ? "typing" : (messages.last?.id ?? UUID())
        withAnimation(.snappy) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// A time header before the first message and after any gap of an hour or more.
    private func shouldShowTimestamp(for message: Message, after previous: Message?) -> Bool {
        guard let previous else { return true }
        return message.createdAt.timeIntervalSince(previous.createdAt) >= 60 * 60
    }

    private func status(for message: Message) -> MessageStatus? {
        guard message.senderId == me else { return nil }
        switch message.deliveryState {
        case .sending: return nil
        case .failed: return .failed
        case .delivered:
            guard message.id == lastOwnDeliveredID else { return nil }
            if let readAt = message.readAt { return .read(readAt) }
            return .delivered
        }
    }
}

private enum MessageStatus: Equatable {
    case delivered
    case read(Date)
    case failed
}

// MARK: - Message row

private struct MessageRow: View {
    let message: Message
    let isFromMe: Bool
    let isLastInGroup: Bool
    let status: MessageStatus?
    let timeReveal: CGFloat
    let timeRevealWidth: CGFloat
    let onRetry: () -> Void

    private var isFailed: Bool { message.deliveryState == .failed }

    /// One to three emoji and nothing else: shown large without a bubble, like iMessage.
    private var isBigEmoji: Bool {
        let text = message.text.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && text.count <= 3 && text.allSatisfy(\.isEmoji)
    }

    var body: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 6) {
                if isFromMe { Spacer(minLength: 56) }

                bubble
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.text
                        }
                    }

                if isFailed {
                    Button(action: onRetry) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not delivered. Retry")
                }

                if !isFromMe { Spacer(minLength: 56) }
            }

            statusLine
        }
        .padding(.bottom, isLastInGroup ? 8 : 0)
        // Swipe-to-reveal: everything slides left and the time appears on the right.
        .offset(x: -timeReveal)
        .overlay(alignment: .topTrailing) {
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(x: timeRevealWidth - timeReveal + 4)
                .opacity(timeReveal / timeRevealWidth)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if isBigEmoji {
            Text(message.text)
                .font(.system(size: 48))
                .opacity(message.deliveryState == .sending ? 0.5 : 1)
        } else {
            Text(message.text)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isFromMe ? Color.white : Color.primary)
                .background(
                    isFromMe ? Color.blue : Color(.systemGray5),
                    in: BubbleShape(isFromMe: isFromMe, hasTail: isLastInGroup)
                )
                .opacity(message.deliveryState == .sending ? 0.6 : 1)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .delivered:
            Text("Delivered")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
        case .read(let date):
            Text("\(Text("Read").fontWeight(.semibold)) \(Text(date, format: .dateTime.hour().minute()))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
        case .failed:
            Button("Not Delivered", action: onRetry)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.red)
                .padding(.trailing, 30)
        case nil:
            EmptyView()
        }
    }
}

/// iMessage-style bubble. The last bubble in a run gets a tail curling out of the bottom corner
/// (right for yours, left for theirs); the tail draws a few points outside the frame.
private struct BubbleShape: Shape {
    let isFromMe: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(18, rect.height / 2)
        guard hasTail else {
            return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        }

        let w = rect.width
        let h = rect.height
        var path = Path()

        // Drawn for your messages (tail bottom-right), then mirrored for theirs.
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: w - radius, y: 0))
        path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: radius), radius: radius)
        path.addLine(to: CGPoint(x: w, y: h - 12))
        // Tail: out to a point just past the corner, then hook back into the bottom edge.
        path.addCurve(
            to: CGPoint(x: w + 5, y: h),
            control1: CGPoint(x: w, y: h - 4),
            control2: CGPoint(x: w + 3, y: h)
        )
        path.addCurve(
            to: CGPoint(x: w - 7, y: h - 3),
            control1: CGPoint(x: w + 1, y: h + 0.5),
            control2: CGPoint(x: w - 4, y: h - 1)
        )
        path.addCurve(
            to: CGPoint(x: w - radius, y: h),
            control1: CGPoint(x: w - 10, y: h - 0.5),
            control2: CGPoint(x: w - 13, y: h)
        )
        path.addLine(to: CGPoint(x: radius, y: h))
        path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - radius), radius: radius)
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: radius, y: 0), radius: radius)
        path.closeSubpath()

        if isFromMe {
            return path.offsetBy(dx: rect.minX, dy: rect.minY)
        }
        let mirror = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0)
        return path.applying(mirror).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Centered time header, like iMessage: "Today 3:04 PM" with the day in bold.
private struct TimestampHeader: View {
    let date: Date

    private var dayText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        Text("\(Text(dayText).fontWeight(.semibold)) \(Text(date, format: .dateTime.hour().minute()))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}

/// Three pulsing dots in a grey bubble, like iMessage.
private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color(.systemGray))
                        .frame(width: 8, height: 8)
                        .opacity(phase == index ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.systemGray5), in: BubbleShape(isFromMe: false, hasTail: true))
            Spacer(minLength: 56)
        }
        .padding(.top, 4)
        .accessibilityLabel("Typing")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}
