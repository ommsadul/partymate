import SwiftUI

/// Your parties: invitations waiting for an answer, and parties you're going to.
/// There is no feed or search on purpose. You only ever see parties you were invited to.
struct PartiesListView: View {
    @Environment(AppStore.self) private var store

    @State private var path: [UUID] = []
    @State private var isCreating = false
    @State private var isJoining = false

    private var hasNoParties: Bool {
        store.invitations.isEmpty && store.goingParties.isEmpty
    }

    /// A party counts as past 12 hours after it starts.
    private func isPast(_ party: Party) -> Bool {
        party.startsAt < Date.now.addingTimeInterval(-12 * 60 * 60)
    }

    private var hosting: [PartyMembership] {
        store.goingParties.filter { $0.party.hostId == store.currentUserID && !isPast($0.party) }
    }

    private var going: [PartyMembership] {
        store.goingParties.filter { $0.party.hostId != store.currentUserID && !isPast($0.party) }
    }

    /// Most recent first.
    private var past: [PartyMembership] {
        store.goingParties.filter { isPast($0.party) }.reversed()
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if hasNoParties {
                    emptyState
                }

                if !store.invitations.isEmpty {
                    Section("Invitations") {
                        ForEach(store.invitations) { membership in
                            NavigationLink(value: membership.party.id) {
                                PartyRow(
                                    party: membership.party,
                                    goingCount: store.goingCount(for: membership.party.id),
                                    role: .invited
                                )
                            }
                            .contextMenu {
                                Button("Accept Invite", systemImage: "checkmark") {
                                    Task { await store.respond(to: membership.party.id, with: .going) }
                                }
                                Button("Decline", systemImage: "xmark", role: .destructive) {
                                    Task { await store.respond(to: membership.party.id, with: .declined) }
                                }
                            }
                        }
                    }
                }

                partySection("Hosting", hosting, role: .host)
                partySection("Going", going, role: .guest)
                partySection("Past", past, role: .past)
            }
            .navigationTitle("Parties")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Join with Code", systemImage: "ticket") {
                        isJoining = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create Party", systemImage: "plus") {
                        isCreating = true
                    }
                }
            }
            .navigationDestination(for: UUID.self) { partyID in
                PartyDetailView(partyID: partyID)
            }
            .sheet(isPresented: $isCreating) {
                CreatePartyView()
            }
            .sheet(isPresented: $isJoining) {
                JoinPartyView()
                    .presentationDetents([.medium])
            }
            .task {
                await store.loadParties()
            }
            .refreshable {
                await store.loadParties()
            }
            .onChange(of: store.pendingPartyID) { _, newValue in
                // Open the party right after creating or joining it.
                guard let newValue else { return }
                isCreating = false
                isJoining = false
                path = [newValue]
                store.pendingPartyID = nil
            }
        }
    }

    @ViewBuilder
    private func partySection(_ title: String, _ memberships: [PartyMembership], role: PartyRow.Role) -> some View {
        if !memberships.isEmpty {
            Section(title) {
                ForEach(memberships) { membership in
                    NavigationLink(value: membership.party.id) {
                        PartyRow(
                            party: membership.party,
                            goingCount: store.goingCount(for: membership.party.id),
                            role: role,
                            isMine: membership.party.hostId == store.currentUserID
                        )
                    }
                }
            }
        }
    }

    /// Shown in place of the list until you have a party. The header buttons are the actions,
    /// so this explains how partymate works instead of repeating them.
    @ViewBuilder
    private var emptyState: some View {
        Section {
            VStack(spacing: 8) {
                Text("🎈")
                    .font(.system(size: 56))
                    .padding(.bottom, 4)
                Text("No parties yet")
                    .font(.title2.bold())
                Text("Parties you host or get invited to show up here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        .listRowBackground(Color.clear)

        Section("How It Works") {
            HowItWorksRow(
                systemImage: "ticket",
                title: "Host or get invited",
                detail: "Create a party with +, or join one with the code a friend sends you."
            )
            HowItWorksRow(
                systemImage: "checkmark.circle",
                title: "Say you're going",
                detail: "Accept the invite to see who else is coming."
            )
            HowItWorksRow(
                systemImage: "heart",
                title: "Meet people before you arrive",
                detail: "Like each other and you can start chatting."
            )
        }
    }
}

/// One step in the empty-state explainer, styled like Apple's What's New screens.
private struct HowItWorksRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// One party in the list: cover, name, when, and who.
private struct PartyRow: View {
    enum Role {
        case invited, host, guest, past
    }

    let party: Party
    let goingCount: Int
    let role: Role
    /// You're the host.
    var isMine = false

    private var goingSuffix: String {
        goingCount > 1 ? ", \(goingCount) going" : ""
    }

    private var whoLine: String {
        switch role {
        case .invited: "\(party.hostName) invited you\(goingSuffix)"
        case .host: "You're hosting\(goingSuffix)"
        case .guest: "Hosted by \(party.hostName)\(goingSuffix)"
        case .past: isMine ? "You hosted" : "Hosted by \(party.hostName)"
        }
    }

    private var isPending: Bool { role == .invited }

    var body: some View {
        HStack(spacing: 14) {
            PartyCover(emoji: party.coverEmoji, photoURL: party.coverURL, size: 50)

            // Dividers start under the name for every row. Without this, an emoji tile
            // (which is text) pulls the divider to the left edge.
            VStack(alignment: .leading, spacing: 2) {
                Text(party.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(party.startsAt.partyTimeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(whoLine)
                    .font(.footnote)
                    .foregroundStyle(isPending ? .primary : .secondary)
                    .fontWeight(isPending ? .semibold : .regular)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 4)
        .opacity(role == .past ? 0.6 : 1)
    }
}

#Preview {
    PartiesListView()
        .environment(AppStore())
}
