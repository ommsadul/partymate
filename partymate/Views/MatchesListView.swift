import SwiftUI

/// Everyone you've matched with, grouped by the party you matched at. Parties with the most
/// recent activity come first; inside each party, chats waiting on you come first.
/// Laid out like Messages.
struct MatchesListView: View {
    @Environment(AppStore.self) private var store

    private var me: UUID? { store.currentUserID }

    private struct PartyGroup: Identifiable {
        let id: UUID
        let name: String
        let matches: [Match]
    }

    private var groups: [PartyGroup] {
        Dictionary(grouping: store.matches, by: \.partyId)
            .map { partyID, matches in
                PartyGroup(
                    id: partyID,
                    name: matches.first?.party?.name ?? "Party",
                    matches: matches.sorted { a, b in
                        let aTurn = a.isYourTurn(for: me)
                        let bTurn = b.isYourTurn(for: me)
                        if aTurn != bTurn { return aTurn }
                        return a.lastActivity > b.lastActivity
                    }
                )
            }
            .sorted { a, b in
                (a.matches.map(\.lastActivity).max() ?? .distantPast) > (b.matches.map(\.lastActivity).max() ?? .distantPast)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(group.name) {
                        ForEach(group.matches) { match in
                            NavigationLink(value: match.id) {
                                MatchRow(
                                    match: match,
                                    me: me,
                                    alsoGoingTo: alsoGoingTo(for: match)
                                )
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Unmatch", systemImage: "heart.slash", role: .destructive) {
                                    Task {
                                        if await store.unmatch(match.id) {
                                            await store.loadMatches()
                                        }
                                    }
                                }
                            }
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 80 }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.matches.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No Matches Yet")
                        } icon: {
                            Text("💌")
                        }
                    } description: {
                        Text("Accept a party invite and meet the guests. When you both like each other, they show up here.")
                    }
                }
            }
            .navigationTitle("Matches")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: UUID.self) { matchID in
                ChatView(matchID: matchID)
            }
            .task {
                await store.loadMatches()
            }
            .refreshable {
                await store.loadMatches()
            }
        }
    }

    /// Other upcoming parties you're both going to, besides the one in this section.
    private func alsoGoingTo(for match: Match) -> [Party] {
        guard let me, let other = match.otherProfile(for: me) else { return [] }
        return store.sharedParties(with: other.id).filter { $0.id != match.partyId }
    }

    private func name(of match: Match) -> String? {
        me.flatMap { match.otherProfile(for: $0)?.name }
    }
}

private extension Match {
    /// Your move: they sent the last message, or nobody has said anything yet.
    func isYourTurn(for me: UUID?) -> Bool {
        guard let last = lastMessage else { return true }
        return last.senderId != me
    }

    var lastActivity: Date {
        lastMessage?.createdAt ?? createdAt
    }
}

/// One match, laid out like Messages: photo, name and time, last message (or a prompt to say hi),
/// and any other parties you're both going to.
private struct MatchRow: View {
    let match: Match
    let me: UUID?
    let alsoGoingTo: [Party]

    private var other: Profile? {
        me.flatMap(match.otherProfile(for:))
    }

    private var hasUnread: Bool {
        me.map(match.hasUnread(for:)) ?? false
    }

    private var isNew: Bool { match.lastMessage == nil }

    private var preview: String {
        guard let last = match.lastMessage else { return "New match. Say hi." }
        return last.senderId == me ? "You: \(last.text)" : last.text
    }

    private var timeText: String {
        let date = match.lastMessage?.createdAt ?? match.createdAt
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: .now).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Short enough for one line. The chat lists the parties by name.
    private var alsoGoingText: String {
        switch alsoGoingTo.count {
        case 0: ""
        case 1: "Also both going to \(alsoGoingTo[0].name)"
        default: "Also both going to \(alsoGoingTo.count) other parties"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: other?.avatarURL, size: 56)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(other?.name ?? "Someone")
                        .font(.headline)
                        .lineLimit(1)
                    if hasUnread {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                    Spacer(minLength: 8)
                    Text(timeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(preview)
                    .font(.subheadline)
                    .fontWeight(hasUnread || isNew ? .semibold : .regular)
                    .foregroundStyle(hasUnread || isNew ? .primary : .secondary)
                    .lineLimit(2)

                if !alsoGoingTo.isEmpty {
                    Text(alsoGoingText)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    MatchesListView()
        .environment(AppStore())
}
