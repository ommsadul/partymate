import Foundation
import Observation
import Supabase

/// The app's single source of truth. Talks to Supabase and keeps the data views read.
@MainActor
@Observable
final class AppStore {
    enum AuthState: Equatable {
        case loading
        case signedOut
        /// Signed in, but hasn't filled in a profile yet.
        case needsProfile(userId: UUID)
        case signedIn
    }

    private(set) var authState: AuthState = .loading
    private(set) var currentProfile: Profile?

    private(set) var memberships: [PartyMembership] = [] {
        didSet { recomputePartyLists() }
    }
    /// Parties you haven't answered yet.
    private(set) var invitations: [PartyMembership] = []
    /// Parties you accepted (including ones you host).
    private(set) var goingParties: [PartyMembership] = []
    /// How many people are going, per party.
    private(set) var goingCounts: [UUID: Int] = [:]

    private(set) var matches: [Match] = []
    /// For each person you've matched with: ids of the parties you're both going to.
    private(set) var sharedPartyIDs: [UUID: Set<UUID>] = [:]
    /// Messages grouped by match, oldest first.
    private(set) var messagesByMatch: [UUID: [Message]] = [:]
    /// When the other person in a chat last signalled they were typing.
    private(set) var typingUntil: [UUID: Date] = [:]

    /// Set when the app should open a party, e.g. right after joining via an invite link.
    var pendingPartyID: UUID?
    /// An invite code opened before the user was signed in. Used once they are.
    private var pendingInviteCode: String?

    var errorMessage: String?
    var isShowingError = false

    private let client = Backend.client
    /// Live chat channels, one per open conversation.
    private var chatChannels: [UUID: RealtimeChannelV2] = [:]
    private var lastTypingSent: [UUID: Date] = [:]

    var currentUserID: UUID? {
        if let currentProfile { return currentProfile.id }
        if case .needsProfile(let userId) = authState { return userId }
        return nil
    }

    // MARK: - Session

    /// Keeps `authState` in sync with Supabase for as long as the calling task lives.
    func observeSession() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .userUpdated:
                if let session {
                    await loadProfile(for: session.user)
                } else {
                    clearUserData()
                    authState = .signedOut
                }
            case .signedOut:
                clearUserData()
                authState = .signedOut
            default:
                break
            }
        }
    }

    private func loadProfile(for user: User) async {
        do {
            let profiles: [Profile] = try await client
                .from("profiles")
                .select()
                .eq("id", value: user.id)
                .limit(1)
                .execute()
                .value

            if let profile = profiles.first {
                currentProfile = profile
                authState = .signedIn
                await joinPendingPartyIfNeeded()
            } else {
                authState = .needsProfile(userId: user.id)
            }
        } catch {
            report(error)
            if authState == .loading {
                authState = .signedOut
            }
        }
    }

    /// Emails a sign-in link. Opening it brings the user back into the app, signed in.
    func sendMagicLink(to email: String) async -> Bool {
        do {
            try await client.auth.signInWithOTP(
                email: email,
                redirectTo: Backend.loginRedirectURL
            )
            return true
        } catch {
            report(error)
            return false
        }
    }

    #if DEBUG
    /// Testing shortcut: signs in as a throwaway anonymous user, no email needed.
    /// Needs Authentication > Sign In / Providers > "Allow anonymous sign-ins" turned on in Supabase.
    /// Remove before launch.
    func signInForTesting() async {
        do {
            try await client.auth.signInAnonymously()
            // authStateChanges delivers the signed-in session from here.
        } catch {
            report(error)
        }
    }
    #endif

    func signOut() async {
        do {
            try await client.auth.signOut()
        } catch {
            report(error)
        }
    }

    /// Permanently deletes your account: your photos, profile, the parties you host, and all
    /// your matches and chats. Returns true on success (you're signed out afterwards).
    func deleteAccount() async -> Bool {
        guard let me = currentUserID else { return false }
        do {
            // Photos first: they live in storage, which the database function can't reach.
            let folder = me.uuidString.lowercased()
            let files = try await client.storage.from("avatars").list(path: folder)
            let paths = files.map { "\(folder)/\($0.name)" }
            if !paths.isEmpty {
                _ = try await client.storage.from("avatars").remove(paths: paths)
            }

            try await client.rpc("delete_my_account").execute()
            try? await client.auth.signOut()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Handles links that open the app: sign-in callbacks and party invites.
    /// Invites arrive as partymate://join/<code> or https://<your domain>/join/<code>.
    func handle(url: URL) {
        if let code = Backend.inviteCode(from: url) {
            if authState == .signedIn {
                Task { await joinParty(code: code) }
            } else {
                pendingInviteCode = code
            }
        } else {
            Task { await completeSignIn(from: url) }
        }
    }

    /// Finishes sign-in from the link in the email.
    private func completeSignIn(from url: URL) async {
        do {
            _ = try await client.auth.session(from: url)
            // authStateChanges delivers the signed-in session from here.
        } catch {
            report(error)
        }
    }

    private func joinPendingPartyIfNeeded() async {
        guard let code = pendingInviteCode else { return }
        pendingInviteCode = nil
        await joinParty(code: code)
    }

    private func clearUserData() {
        currentProfile = nil
        memberships = []
        goingCounts = [:]
        matches = []
        messagesByMatch = [:]
        typingUntil = [:]
        pendingPartyID = nil
    }

    // MARK: - Profile

    /// Uploads one profile photo and returns its public URL.
    func uploadPhoto(_ jpegData: Data) async -> URL? {
        guard let userID = currentUserID else { return nil }
        // Files live in a folder named after the user (the storage rules rely on this).
        let path = "\(userID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        do {
            try await client.storage
                .from("avatars")
                .upload(path, data: jpegData, options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: false))
            return try client.storage.from("avatars").getPublicURL(path: path)
        } catch {
            report(error)
            return nil
        }
    }

    func saveProfile(name: String, bio: String, instagram: String?, photoURLs: [URL]) async {
        guard let userID = currentUserID else { return }
        let urls = photoURLs.map(\.absoluteString)
        let profile = Profile(
            id: userID,
            name: name,
            bio: bio,
            instagram: instagram,
            avatarUrl: urls.first,
            photoUrls: urls
        )
        do {
            try await client.from("profiles").upsert(profile).execute()
            currentProfile = profile
            if authState != .signedIn {
                authState = .signedIn
                await joinPendingPartyIfNeeded()
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Parties

    func loadParties() async {
        guard let me = currentUserID else { return }
        do {
            let rows: [PartyMembership] = try await client
                .from("party_members")
                .select("status, party:parties!party_members_party_id_fkey(*, host:profiles!parties_host_id_fkey(name))")
                .eq("user_id", value: me)
                .execute()
                .value
            memberships = rows.sorted { $0.party.startsAt < $1.party.startsAt }
            await loadGoingCounts(for: rows.map(\.party.id))
        } catch {
            report(error)
        }
    }

    private func loadGoingCounts(for partyIDs: [UUID]) async {
        guard !partyIDs.isEmpty else {
            goingCounts = [:]
            return
        }
        do {
            let counts: [GoingCount] = try await client
                .rpc("party_going_counts", params: ["p_party_ids": partyIDs])
                .execute()
                .value
            goingCounts = Dictionary(uniqueKeysWithValues: counts.map { ($0.partyId, $0.goingCount) })
        } catch {
            report(error)
        }
    }

    func membership(for partyID: UUID) -> PartyMembership? {
        memberships.first { $0.party.id == partyID }
    }

    func goingCount(for partyID: UUID) -> Int {
        goingCounts[partyID] ?? 0
    }

    /// Accept, decline, or leave a party. Leaving a party you were going to
    /// also removes your likes and matches from it (done by the database).
    func respond(to partyID: UUID, with status: InviteStatus) async {
        guard let me = currentUserID else { return }
        do {
            try await client
                .from("party_members")
                .update(["status": status.rawValue])
                .eq("party_id", value: partyID)
                .eq("user_id", value: me)
                .execute()
            if let index = memberships.firstIndex(where: { $0.party.id == partyID }) {
                memberships[index].status = status
            }
            await loadGoingCounts(for: memberships.map(\.party.id))
            if status != .going {
                await loadMatches()
            }
        } catch {
            report(error)
        }
    }

    /// Creates a party you host. Returns the new party's id, or nil if it failed.
    /// Creates a party. `coverPhoto` is an optional JPEG shown instead of the emoji.
    func createParty(name: String, startsAt: Date, location: String, details: String, coverEmoji: String, coverPhoto: Data? = nil) async -> UUID? {
        guard let me = currentUserID else { return nil }
        var coverURL: URL?
        if let coverPhoto {
            guard let uploaded = await uploadPhoto(coverPhoto) else { return nil }
            coverURL = uploaded
        }
        let newParty = NewParty(
            hostId: me,
            name: name,
            startsAt: startsAt,
            location: location,
            details: details,
            coverEmoji: coverEmoji,
            coverUrl: coverURL?.absoluteString
        )
        do {
            let party: Party = try await client
                .from("parties")
                .insert(newParty)
                .select("*, host:profiles!parties_host_id_fkey(name)")
                .single()
                .execute()
                .value
            await loadParties()
            return party.id
        } catch {
            report(error)
            return nil
        }
    }

    /// How an edit changes a party's cover photo.
    enum CoverPhotoChange {
        case keep
        case replace(Data)
        case remove
    }

    /// Saves the host's edits to a party. Returns true on success.
    func updateParty(_ partyID: UUID, name: String, startsAt: Date, location: String, details: String, coverEmoji: String, photo: CoverPhotoChange) async -> Bool {
        var coverURL = PartyUpdate.CoverURL.unchanged
        switch photo {
        case .keep:
            break
        case .replace(let data):
            guard let uploaded = await uploadPhoto(data) else { return false }
            coverURL = .set(uploaded.absoluteString)
        case .remove:
            coverURL = .clear
        }
        let changes = PartyUpdate(
            name: name,
            startsAt: startsAt,
            location: location,
            details: details,
            coverEmoji: coverEmoji,
            coverUrl: coverURL
        )
        do {
            try await client
                .from("parties")
                .update(changes)
                .eq("id", value: partyID)
                .execute()
            await loadParties()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Deletes a party for everyone. Its guest list, likes, matches, and chats go with it.
    /// The caller reloads parties afterwards (after closing any sheet showing the party).
    func deleteParty(_ partyID: UUID) async -> Bool {
        do {
            try await client
                .from("parties")
                .delete()
                .eq("id", value: partyID)
                .execute()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Joins a party from an invite code. Returns the party's id, or nil if it failed.
    @discardableResult
    func joinParty(code: String) async -> UUID? {
        do {
            let partyID: UUID = try await client
                .rpc("join_party", params: ["code": code])
                .execute()
                .value
            await loadParties()
            pendingPartyID = partyID
            return partyID
        } catch {
            report(error)
            return nil
        }
    }

    /// Everyone who said yes to a party, apart from you and anyone blocked either way.
    func guests(in partyID: UUID) async -> [Profile] {
        do {
            let rows: [Profile] = try await client
                .rpc("party_guests", params: ["p_party": partyID])
                .execute()
                .value
            return rows
        } catch {
            report(error)
            return []
        }
    }

    /// People invited to a party who haven't replied yet. Shown to the host.
    func invitedGuests(in partyID: UUID) async -> [Profile] {
        struct Row: Decodable { let profile: Profile }
        do {
            let rows: [Row] = try await client
                .from("party_members")
                .select("profile:profiles!party_members_user_id_fkey(*)")
                .eq("party_id", value: partyID)
                .eq("status", value: InviteStatus.invited.rawValue)
                .execute()
                .value
            return rows.map(\.profile)
        } catch {
            report(error)
            return []
        }
    }

    /// The host removes someone from their party. Their likes and matches there go too.
    func removeGuest(_ userID: UUID, from partyID: UUID) async -> Bool {
        do {
            try await client
                .from("party_members")
                .delete()
                .eq("party_id", value: partyID)
                .eq("user_id", value: userID)
                .execute()
            await loadParties()
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - Matching

    /// Guests at a party you haven't liked or passed on yet.
    func guestsToMeet(in partyID: UUID) async -> [Profile] {
        guard let me = currentUserID else { return [] }
        let guests = await guests(in: partyID)
        do {
            let decided: [LikeRecord] = try await client
                .from("likes")
                .select()
                .eq("party_id", value: partyID)
                .eq("from_user", value: me)
                .execute()
                .value
            let decidedIDs = Set(decided.map(\.toUser))
            return guests.filter { !decidedIDs.contains($0.id) }
        } catch {
            report(error)
            return []
        }
    }

    /// Records a like. Returns true if the other person had already liked you (a match).
    func like(_ profile: Profile, at partyID: UUID) async -> Bool {
        guard let me = currentUserID else { return false }
        do {
            try await client
                .from("likes")
                .upsert(LikeRecord(partyId: partyID, fromUser: me, toUser: profile.id, isLike: true))
                .execute()

            // The database creates the match row when the like is mutual.
            // Matches store the smaller id as user_a, so look it up the same way.
            let (userA, userB) = me.uuidString.lowercased() < profile.id.uuidString.lowercased()
                ? (me, profile.id)
                : (profile.id, me)
            let found: [Match] = try await client
                .from("matches")
                .select("id, party_id, user_a, user_b, created_at")
                .eq("party_id", value: partyID)
                .eq("user_a", value: userA)
                .eq("user_b", value: userB)
                .limit(1)
                .execute()
                .value

            if found.isEmpty { return false }
            await loadMatches()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func pass(on profile: Profile, at partyID: UUID) async {
        guard let me = currentUserID else { return }
        do {
            try await client
                .from("likes")
                .upsert(LikeRecord(partyId: partyID, fromUser: me, toUser: profile.id, isLike: false))
                .execute()
        } catch {
            report(error)
        }
    }

    func loadMatches() async {
        do {
            let rows: [Match] = try await client
                .from("matches")
                .select("""
                    *, \
                    party:parties!matches_party_id_fkey(name), \
                    profile_a:profiles!matches_user_a_fkey(*), \
                    profile_b:profiles!matches_user_b_fkey(*), \
                    messages(*)
                    """)
                .order("created_at", ascending: false)
                .order("created_at", ascending: false, referencedTable: "messages")
                .limit(1, referencedTable: "messages")
                .execute()
                .value
            matches = rows
            if let me = currentUserID {
                await loadSharedParties(with: rows.compactMap { $0.otherProfile(for: me)?.id })
            }
        } catch {
            report(error)
        }
    }

    /// True if you've matched with this person at any party. Full profiles in a guest list
    /// only open for matches.
    func isMatched(with person: UUID) -> Bool {
        guard let me = currentUserID else { return false }
        return matches.contains { $0.otherProfile(for: me)?.id == person }
    }

    /// Finds which of your parties each person is also going to.
    func loadSharedParties(with people: [UUID]) async {
        let myParties = memberships.filter { $0.status == .going }.map(\.party.id)
        guard !people.isEmpty, !myParties.isEmpty else { return }
        struct Row: Decodable {
            let partyId: UUID
            let userId: UUID
            enum CodingKeys: String, CodingKey {
                case partyId = "party_id"
                case userId = "user_id"
            }
        }
        do {
            let rows: [Row] = try await client
                .from("party_members")
                .select("party_id, user_id")
                .in("user_id", values: people.map(\.uuidString))
                .in("party_id", values: myParties.map(\.uuidString))
                .eq("status", value: InviteStatus.going.rawValue)
                .execute()
                .value
            var found: [UUID: Set<UUID>] = Dictionary(uniqueKeysWithValues: people.map { ($0, []) })
            for row in rows {
                found[row.userId, default: []].insert(row.partyId)
            }
            sharedPartyIDs.merge(found) { _, new in new }
        } catch {
            report(error)
        }
    }

    /// Upcoming parties you and this person are both going to, soonest first.
    func sharedParties(with person: UUID) -> [Party] {
        let ids = sharedPartyIDs[person] ?? []
        let cutoff = Date.now.addingTimeInterval(-12 * 60 * 60)
        return memberships
            .filter { $0.status == .going && ids.contains($0.party.id) && $0.party.startsAt > cutoff }
            .map(\.party)
    }

    func match(withID id: UUID) -> Match? {
        matches.first { $0.id == id }
    }

    // MARK: - Safety

    func unmatch(_ matchID: UUID) async -> Bool {
        do {
            try await client.from("matches").delete().eq("id", value: matchID).execute()
            matches.removeAll { $0.id == matchID }
            messagesByMatch[matchID] = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Blocks a person. The database removes any match and likes between you.
    func block(_ userID: UUID) async -> Bool {
        guard let me = currentUserID else { return false }
        do {
            try await client
                .from("blocks")
                .upsert(NewBlock(blockerId: me, blockedId: userID))
                .execute()
            matches.removeAll { $0.userA == userID || $0.userB == userID }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func report(_ userID: UUID, reason: ReportReason, details: String, partyID: UUID?) async -> Bool {
        guard let me = currentUserID else { return false }
        do {
            try await client
                .from("reports")
                .insert(NewReport(
                    reporterId: me,
                    reportedId: userID,
                    partyId: partyID,
                    reason: reason.rawValue,
                    details: details.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                .execute()
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - Chat

    func messages(for matchID: UUID) -> [Message] {
        messagesByMatch[matchID] ?? []
    }

    func isOtherTyping(in matchID: UUID) -> Bool {
        guard let until = typingUntil[matchID] else { return false }
        return until > .now
    }

    func loadMessages(for matchID: UUID) async {
        do {
            let rows: [Message] = try await client
                .from("messages")
                .select()
                .eq("match_id", value: matchID)
                .order("created_at")
                .execute()
                .value
            // Keep any messages that are still on their way to the server.
            let pending = (messagesByMatch[matchID] ?? []).filter { $0.deliveryState != .delivered }
            let serverIDs = Set(rows.map(\.id))
            messagesByMatch[matchID] = rows + pending.filter { !serverIDs.contains($0.id) }
        } catch {
            report(error)
        }
    }

    /// Shows the message immediately, then sends it. Marks it failed if the send doesn't go through.
    func send(_ text: String, in matchID: UUID) async {
        guard let me = currentUserID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = UUID()
        var optimistic = Message(id: id, matchId: matchID, senderId: me, text: trimmed, createdAt: .now)
        optimistic.deliveryState = .sending
        messagesByMatch[matchID, default: []].append(optimistic)

        do {
            let saved: Message = try await client
                .from("messages")
                .insert(NewMessage(id: id, matchId: matchID, senderId: me, text: trimmed))
                .select()
                .single()
                .execute()
                .value
            replace(messageID: id, in: matchID, with: saved)
            refreshMatchPreview(matchID: matchID, with: saved)
        } catch {
            update(messageID: id, in: matchID) { $0.deliveryState = .failed }
        }
    }

    /// Tries again for a message that didn't go through.
    func retry(_ message: Message) async {
        guard message.deliveryState == .failed else { return }
        messagesByMatch[message.matchId]?.removeAll { $0.id == message.id }
        await send(message.text, in: message.matchId)
    }

    /// Marks everything the other person sent in this chat as read.
    func markRead(_ matchID: UUID) async {
        guard let me = currentUserID else { return }
        let unread = messages(for: matchID).filter { $0.senderId != me && $0.readAt == nil }
        guard !unread.isEmpty else { return }
        do {
            try await client
                .from("messages")
                .update(["read_at": Date.now])
                .eq("match_id", value: matchID)
                .neq("sender_id", value: me)
                .is("read_at", value: nil)
                .execute()
            let now = Date.now
            for message in unread {
                update(messageID: message.id, in: matchID) { $0.readAt = now }
            }
            if let index = matches.firstIndex(where: { $0.id == matchID }),
               var last = matches[index].lastMessage, last.senderId != me {
                last.readAt = now
                matches[index].latestMessages = [last]
            }
        } catch {
            // Read receipts are best-effort; don't interrupt the chat for them.
        }
    }

    /// Tells the other person you're typing. Throttled so it doesn't flood the connection.
    func sendTyping(in matchID: UUID) {
        guard let me = currentUserID, let channel = chatChannels[matchID] else { return }
        if let last = lastTypingSent[matchID], Date.now.timeIntervalSince(last) < 2 { return }
        lastTypingSent[matchID] = .now
        Task {
            try? await channel.broadcast(event: "typing", message: ["user_id": .string(me.uuidString)])
        }
    }

    /// Keeps one chat live (new messages, read receipts, typing) until the calling task is cancelled.
    func listenForMessages(in matchID: UUID) async {
        guard let me = currentUserID else { return }
        let channel = client.channel("chat-\(matchID.uuidString.lowercased())")
        chatChannels[matchID] = channel

        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "messages")
        let typing = channel.broadcastStream(event: "typing")
        do {
            try await channel.subscribeWithError()
        } catch {
            // Live updates are a nice-to-have; the chat still loads and sends without them.
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await change in changes {
                    let record: [String: AnyJSON]
                    switch change {
                    case .insert(let action): record = action.record
                    case .update(let action): record = action.record
                    case .delete: continue
                    }
                    guard record["match_id"]?.stringValue?.lowercased() == matchID.uuidString.lowercased() else { continue }
                    await self.loadMessages(for: matchID)
                    await self.markRead(matchID)
                }
            }
            group.addTask { @MainActor in
                for await payload in typing {
                    let sender = payload["payload"]?.objectValue?["user_id"]?.stringValue
                        ?? payload["user_id"]?.stringValue
                    guard sender?.lowercased() != me.uuidString.lowercased() else { continue }
                    self.typingUntil[matchID] = .now.addingTimeInterval(3)
                    Task {
                        try? await Task.sleep(for: .seconds(3.1))
                        if let until = self.typingUntil[matchID], until <= .now {
                            self.typingUntil[matchID] = nil
                        }
                    }
                }
            }
        }

        chatChannels[matchID] = nil
        await client.removeChannel(channel)
    }

    private func replace(messageID: UUID, in matchID: UUID, with message: Message) {
        guard var list = messagesByMatch[matchID] else { return }
        if let index = list.firstIndex(where: { $0.id == messageID }) {
            list[index] = message
        } else {
            list.append(message)
        }
        messagesByMatch[matchID] = list
    }

    private func update(messageID: UUID, in matchID: UUID, _ change: (inout Message) -> Void) {
        guard var list = messagesByMatch[matchID],
              let index = list.firstIndex(where: { $0.id == messageID }) else { return }
        change(&list[index])
        messagesByMatch[matchID] = list
    }

    private func refreshMatchPreview(matchID: UUID, with message: Message) {
        guard let index = matches.firstIndex(where: { $0.id == matchID }) else { return }
        matches[index].latestMessages = [message]
    }

    // MARK: - Push notifications

    /// Saves this device's push token so the server can notify this user.
    func registerDeviceToken(_ token: String) async {
        guard let me = currentUserID else { return }
        do {
            try await client
                .from("device_tokens")
                .upsert(DeviceTokenRecord(token: token, userId: me, platform: "ios"))
                .execute()
        } catch {
            // Not worth bothering the user about.
        }
    }

    // MARK: - Helpers

    private func recomputePartyLists() {
        invitations = memberships.filter { $0.status == .invited }
        goingParties = memberships.filter { $0.status == .going }
    }

    private func report(_ error: Error) {
        // A load that was cancelled (for example by leaving the screen) isn't a failure.
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return
        }
        errorMessage = friendlyMessage(for: error)
        isShowingError = true
    }

    /// Turns raw database errors into something a person can act on.
    private func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        if raw.localizedCaseInsensitiveContains("offline") || raw.localizedCaseInsensitiveContains("network connection") {
            return "You're offline. Check your connection and try again."
        }
        if raw.localizedCaseInsensitiveContains("rate limit") {
            return "Too many attempts. Give it a few minutes and try again."
        }
        if raw.localizedCaseInsensitiveContains("No party found") {
            return "No party found for that invite code. Double-check it with the host."
        }
        if raw.localizedCaseInsensitiveContains("delete_my_account") {
            return "Account deletion needs a database update. Run supabase/05-delete-account.sql in Supabase (see SETUP.md)."
        }
        if raw.localizedCaseInsensitiveContains("cover_url") {
            return "Party photos need a database update. Run supabase/04-party-covers.sql in Supabase (see SETUP.md), or use an emoji for now."
        }
        if raw.localizedCaseInsensitiveContains("row-level security") {
            return "You don't have access to that."
        }
        return raw
    }
}
