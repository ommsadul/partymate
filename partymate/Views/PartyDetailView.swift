import SwiftUI

/// Details for one party. The full guest list opens up once you accept the invite.
struct PartyDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let partyID: UUID

    var body: some View {
        if let membership = store.membership(for: partyID) {
            PartyDetailContent(party: membership.party, status: membership.status)
        } else {
            ProgressView()
                .task {
                    await store.loadParties()
                    // The party is gone (deleted by the host), so go back to the list.
                    if store.membership(for: partyID) == nil {
                        dismiss()
                    }
                }
        }
    }
}

private struct PartyDetailContent: View {
    @Environment(AppStore.self) private var store
    let party: Party
    let status: InviteStatus

    @State private var guests: [Profile] = []
    @State private var invited: [Profile] = []
    @State private var isResponding = false
    @State private var isEditing = false
    @State private var isMeetingGuests = false
    @State private var previewing: Profile?
    /// True once the header has scrolled away, so the name moves into the navigation bar.
    @State private var showsTitle = false

    private var isHost: Bool {
        party.hostId == store.currentUserID
    }

    /// Everyone going, counting you if you're going.
    private var goingCount: Int {
        store.goingCount(for: party.id)
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))

            primaryAction

            detailsSection

            switch status {
            case .invited:
                EmptyView()
            case .going:
                if isHost {
                    inviteSection
                    if !invited.isEmpty {
                        waitingSection
                    }
                    guestSection
                } else {
                    guestSection
                    inviteSection
                    Section {
                        Button("Leave Party", role: .destructive) {
                            Task { await respond(.declined) }
                        }
                        .disabled(isResponding)
                    }
                }
            case .declined:
                Section {
                    Button("I'm Going After All") {
                        Task { await respond(.going) }
                    }
                    .disabled(isResponding)
                } footer: {
                    Text("You declined this invite.")
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 240
        } action: { _, isPastHeader in
            withAnimation(.easeInOut(duration: 0.15)) {
                showsTitle = isPastHeader
            }
        }
        .navigationTitle(showsTitle ? party.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isHost {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") {
                        isEditing = true
                    }
                }
            }
        }
        .navigationDestination(isPresented: $isMeetingGuests) {
            GuestDeckView(party: party)
        }
        .sheet(isPresented: $isEditing) {
            CreatePartyView(editing: party) {
                Task { await store.loadParties() }
            }
        }
        .sheet(item: $previewing) { profile in
            ProfilePreviewSheet(profile: profile)
        }
        .task(id: status) {
            await reloadGuests()
        }
        .refreshable {
            await reloadGuests()
            await store.loadParties()
        }
    }

    // MARK: - Header and main action

    /// Centered header: cover, name, host, and a few faces.
    private var header: some View {
        VStack(spacing: 10) {
            coverArt
                .padding(.bottom, 4)
            Text(party.name)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(isHost ? "You're hosting" : "Hosted by \(party.hostName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if !guests.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(guests.prefix(5)) { guest in
                            AvatarView(url: guest.avatarURL, size: 28)
                                .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2))
                        }
                    }
                }
                Text(goingText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(goingCount == 0 ? .secondary : .primary)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// A wide photo banner if the party has a cover photo, otherwise the emoji tile.
    @ViewBuilder
    private var coverArt: some View {
        if let coverURL = party.coverURL {
            Color.clear
                .frame(height: 180)
                .overlay {
                    AsyncImage(url: coverURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color(.tertiarySystemFill)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityHidden(true)
        } else {
            EmojiTile(emoji: party.coverEmoji, size: 88)
        }
    }

    private var goingText: String {
        switch goingCount {
        case 0: "Nobody has said yes yet"
        case 1: status == .going ? "Just you so far" : "1 person going"
        default: "\(goingCount) going"
        }
    }

    /// The one thing to do next: answer the invite, or meet the guests.
    @ViewBuilder
    private var primaryAction: some View {
        switch status {
        case .invited:
            Section {
                ActionBlock(note: "Accept to see the guest list and meet people before the party.") {
                    HStack(spacing: 12) {
                        Button {
                            Task { await respond(.declined) }
                        } label: {
                            ButtonText("Decline")
                        }
                        .secondaryActionStyle()

                        Button {
                            Task { await respond(.going) }
                        } label: {
                            ButtonText("Accept")
                        }
                        .prominentActionStyle()
                    }
                    .disabled(isResponding)
                }
            }
        case .going where !guests.isEmpty:
            Section {
                ActionBlock(note: "Like the people you want to meet. They only find out if they like you too.") {
                    Button {
                        isMeetingGuests = true
                    } label: {
                        ButtonText("Meet the Guests", systemImage: "person.2.fill")
                    }
                    .prominentActionStyle()
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section {
            Label(party.startsAt.partyTimeText, systemImage: "calendar")
            if !party.location.isEmpty {
                if let mapsURL {
                    Link(destination: mapsURL) {
                        HStack {
                            Label(party.location, systemImage: "mappin.and.ellipse")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Opens in Maps")
                } else {
                    Label(party.location, systemImage: "mappin.and.ellipse")
                }
            }
            if !party.details.isEmpty {
                Label(party.details, systemImage: "text.alignleft")
            }
        }
    }

    private var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: party.location)]
        return components?.url
    }

    /// Share link and code so friends can join.
    private var inviteSection: some View {
        Section("Invite Friends") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(party.inviteCode)
                        .font(.title3.weight(.semibold))
                        .tracking(2)
                        .textSelection(.enabled)
                }
                Spacer()
                if let url = Backend.inviteURL(code: party.inviteCode) {
                    ShareLink(
                        item: url,
                        subject: Text(party.name),
                        message: Text("Join \(party.name) on partymate! Invite code: \(party.inviteCode)")
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Host only: people invited who haven't answered yet.
    private var waitingSection: some View {
        Section {
            ForEach(invited) { person in
                guestRow(person)
            }
        } header: {
            Text("Waiting to Reply (\(invited.count))")
        } footer: {
            Text("They can see the party, but not the guest list, until they accept.")
        }
    }

    private var guestSection: some View {
        Section {
            if guests.isEmpty {
                Text("Nobody else has accepted yet. Share the invite code to get people in.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(guests) { guest in
                    guestRow(guest)
                }
            }
        } header: {
            Text("Guests")
        } footer: {
            if !guests.isEmpty {
                Text(isHost
                     ? "You can see someone's full profile once you match. Swipe left on a guest to remove them from the party."
                     : "You can see someone's full profile once you match.")
            }
        }
    }

    /// Matches can be tapped to see their full profile; everyone else is just a face and a name.
    /// The host can swipe to remove anyone.
    @ViewBuilder
    private func guestRow(_ person: Profile) -> some View {
        let isMatch = store.isMatched(with: person.id)
        Group {
            if isMatch {
                Button {
                    previewing = person
                } label: {
                    guestLabel(person, isMatch: true)
                }
                .accessibilityHint("Shows their profile")
            } else {
                guestLabel(person, isMatch: false)
            }
        }
        .swipeActions(edge: .trailing) {
            if isHost {
                Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                    Task {
                        if await store.removeGuest(person.id, from: party.id) {
                            await reloadGuests()
                        }
                    }
                }
            }
        }
    }

    private func guestLabel(_ person: Profile, isMatch: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: person.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                    .foregroundStyle(.primary)
                if isMatch {
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                        Text("Matched")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isMatch {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reloadGuests() async {
        await store.loadMatches()
        guests = await store.guests(in: party.id)
        if isHost {
            invited = await store.invitedGuests(in: party.id)
        }
    }

    private func respond(_ newStatus: InviteStatus) async {
        isResponding = true
        defer { isResponding = false }
        await store.respond(to: party.id, with: newStatus)
    }
}
