import SwiftUI

/// Swipe through the guests at a party. Right (or the heart) likes, left (or the X) passes.
/// A match happens when someone you like has already liked you.
struct GuestDeckView: View {
    @Environment(AppStore.self) private var store
    let party: Party

    @State private var deck: [Profile] = []
    @State private var isLoading = true
    @State private var dragOffset: CGSize = .zero
    @State private var matchedGuest: Profile?
    @State private var reporting: Profile?

    private let swipeThreshold: CGFloat = 120

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                if isLoading {
                    ProgressView()
                } else if deck.isEmpty {
                    allDone
                }

                // The next card peeks out from behind the top one.
                if deck.count > 1 {
                    GuestCard(profile: deck[1])
                        .scaleEffect(0.95)
                        .offset(y: 12)
                }

                if let topGuest = deck.first {
                    GuestCard(profile: topGuest) {
                        SafetyMenu(userName: topGuest.name, showsUnmatch: false) {
                        } onBlock: {
                            Task {
                                if await store.block(topGuest.id) {
                                    removeFromDeck(topGuest)
                                }
                            }
                        } onReport: {
                            reporting = topGuest
                        }
                        .foregroundStyle(.white)
                        // A dark tint keeps it readable on bright photos.
                        .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .circle)
                    }
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width / 20)))
                    .overlay {
                        swipeHint
                    }
                    .gesture(dragGesture)
                    .id(topGuest.id)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 32) {
                Button {
                    passTopGuest()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .accessibilityLabel("Pass")

                Button {
                    likeTopGuest()
                } label: {
                    Image(systemName: "heart.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .accessibilityLabel("Like")
            }
            .disabled(deck.isEmpty)
            .opacity(deck.isEmpty ? 0.3 : 1)
            .padding(.bottom, 12)
        }
        .navigationTitle(party.name)
        .navigationSubtitle(isLoading || deck.isEmpty ? "" : "\(deck.count) to meet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sensoryFeedback(.success, trigger: matchedGuest?.id)
        .task {
            deck = await store.guestsToMeet(in: party.id)
            isLoading = false
        }
        .fullScreenCover(item: $matchedGuest) { guest in
            MatchMoment(me: store.currentProfile, them: guest)
        }
        .sheet(item: $reporting) { profile in
            ReportSheet(userID: profile.id, userName: profile.name, partyID: party.id) {
                removeFromDeck(profile)
            }
        }
    }

    private var allDone: some View {
        ContentUnavailableView {
            Label {
                Text("You've Met Everyone")
            } icon: {
                Text("✨")
            }
        } description: {
            Text("Check Matches to see who liked you back.")
        }
    }

    /// A heart or X that fades in over the card as it's dragged.
    private var swipeHint: some View {
        let strength = min(1, abs(dragOffset.width) / swipeThreshold)
        let isLike = dragOffset.width > 0
        return Image(systemName: isLike ? "heart.fill" : "xmark")
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .glassEffect(.regular, in: .circle)
            .scaleEffect(0.8 + 0.2 * strength)
            .opacity(strength)
            .allowsHitTesting(false)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                if value.translation.width > swipeThreshold {
                    likeTopGuest()
                } else if value.translation.width < -swipeThreshold {
                    passTopGuest()
                } else {
                    withAnimation(.spring) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func likeTopGuest() {
        guard let guest = deck.first else { return }
        removeTopCard(flyingTo: 1)
        Task {
            let matched = await store.like(guest, at: party.id)
            if matched {
                matchedGuest = guest
            }
        }
    }

    private func passTopGuest() {
        guard let guest = deck.first else { return }
        removeTopCard(flyingTo: -1)
        Task {
            await store.pass(on: guest, at: party.id)
        }
    }

    private func removeFromDeck(_ profile: Profile) {
        withAnimation(.snappy) {
            deck.removeAll { $0.id == profile.id }
        }
    }

    /// Animates the top card off screen (1 = right, -1 = left), then removes it from the deck.
    private func removeTopCard(flyingTo direction: CGFloat) {
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: direction * 600, height: 0)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            dragOffset = .zero
            if !deck.isEmpty {
                deck.removeFirst()
            }
        }
    }
}

/// Full-bleed photo card. Tap the right half for the next photo, left half for the previous.
/// Instagram only shows when `showsInstagram` is true: for matches and your own preview.
struct GuestCard<Corner: View>: View {
    let profile: Profile
    var showsInstagram = false
    @ViewBuilder let cornerAction: () -> Corner

    @State private var photoIndex = 0

    init(profile: Profile, showsInstagram: Bool = false, @ViewBuilder cornerAction: @escaping () -> Corner) {
        self.profile = profile
        self.showsInstagram = showsInstagram
        self.cornerAction = cornerAction
    }

    private var photos: [URL] { profile.photoURLs }

    var body: some View {
        // The card takes whatever space it's offered; the photo fills it without changing its size.
        // (A scaledToFill image sizes itself to the photo, which pushed wide photos off screen.)
        Color(.secondarySystemBackground)
            .overlay { photoLayer }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard photos.count > 1 else { return }
                // Tap right half for next, left half for previous.
                withAnimation(.easeInOut(duration: 0.15)) {
                    if location.x > 160 {
                        photoIndex = min(photoIndex + 1, photos.count - 1)
                    } else {
                        photoIndex = max(photoIndex - 1, 0)
                    }
                }
            }
            .modifier(CardOverlays(profile: profile, showsInstagram: showsInstagram, photoCount: photos.count, photoIndex: photoIndex, cornerAction: cornerAction))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            // A hairline edge so photos with light backgrounds don't melt into the page.
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var photoLayer: some View {
        ZStack {
            if photos.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, url in
                    if index == photoIndex {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color(.secondarySystemBackground)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
    }
}

/// Photo progress bars and corner button on top, name and bio on the bottom.
private struct CardOverlays<Corner: View>: ViewModifier {
    let profile: Profile
    let showsInstagram: Bool
    let photoCount: Int
    let photoIndex: Int
    let cornerAction: () -> Corner

    func body(content: Content) -> some View {
        content
        .overlay(alignment: .top) {
            HStack(spacing: 10) {
                if photoCount > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<photoCount, id: \.self) { index in
                            Capsule()
                                .fill(.white.opacity(index == photoIndex ? 0.95 : 0.4))
                                .frame(height: 3)
                        }
                    }
                }
                Spacer(minLength: 0)
                cornerAction()
            }
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                if showsInstagram, let instagram = profile.instagram, !instagram.isEmpty {
                    Label("@\(instagram)", systemImage: "camera")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                if !profile.bio.isEmpty {
                    Text(profile.bio)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

extension GuestCard where Corner == EmptyView {
    init(profile: Profile, showsInstagram: Bool = false) {
        self.init(profile: profile, showsInstagram: showsInstagram) { EmptyView() }
    }
}

/// Full-screen match moment. The two photos slide in from either side and meet.
private struct MatchMoment: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let me: Profile?
    let them: Profile

    @State private var hasMet = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: -24) {
                photo(me?.avatarURL)
                    .offset(x: hasMet ? 0 : -260)
                photo(them.avatarURL)
                    .offset(x: hasMet ? 0 : 260)
            }

            VStack(spacing: 10) {
                Text("It's a Match")
                    .font(.largeTitle.bold())
                Text("You and \(them.name) liked each other. Say hi from Matches.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let shared = bothGoingText(store.sharedParties(with: them.id)) {
                    Text(shared)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 36)
            .opacity(hasMet ? 1 : 0)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Keep Swiping")
                    .frame(maxWidth: .infinity)
            }
            .prominentActionStyle()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.3)) {
                hasMet = true
            }
        }
        .task {
            await store.loadSharedParties(with: [them.id])
        }
    }

    private func photo(_ url: URL?) -> some View {
        AvatarView(url: url, size: 140)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 4))
    }
}

/// Someone's profile card in a sheet, as guests see it when swiping.
/// Used from the guest list, the chat header, and "See How Others See You".
struct ProfilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: Profile

    var body: some View {
        NavigationStack {
            GuestCard(profile: profile, showsInstagram: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .navigationTitle(profile.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                    }
                    if let url = profile.instagramURL {
                        ToolbarItem(placement: .topBarTrailing) {
                            Link(destination: url) {
                                Label("Open Instagram", systemImage: "camera")
                            }
                        }
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}
