import Foundation

// These structs mirror the database tables in supabase/*.sql.
// CodingKeys map Swift's camelCase names to the snake_case column names.

/// A person using the app. One row per signed-in user.
struct Profile: Codable, Identifiable, Hashable {
    static let maxPhotos = 6

    let id: UUID
    var name: String
    var bio: String
    var instagram: String?
    /// Main photo. Kept in sync with the first entry of `photoUrls`.
    var avatarUrl: String?
    /// All photos, main one first.
    var photoUrls: [String]

    var avatarURL: URL? {
        (avatarUrl ?? photoUrls.first).flatMap(URL.init(string:))
    }

    var photoURLs: [URL] {
        let urls = photoUrls.compactMap(URL.init(string:))
        if urls.isEmpty, let avatarURL { return [avatarURL] }
        return urls
    }

    /// Link to their Instagram profile, if they added a handle.
    var instagramURL: URL? {
        guard let instagram, !instagram.isEmpty else { return nil }
        return URL(string: "https://instagram.com/\(instagram)")
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bio, instagram
        case avatarUrl = "avatar_url"
        case photoUrls = "photo_urls"
    }
}

/// Where you stand with a party invitation.
enum InviteStatus: String, Codable, Equatable {
    case invited
    case going
    case declined
}

struct Party: Codable, Identifiable, Equatable {
    let id: UUID
    let hostId: UUID
    var name: String
    var startsAt: Date
    var location: String
    var details: String
    var coverEmoji: String
    /// Optional cover photo, shown instead of the emoji.
    var coverUrl: String?
    let inviteCode: String
    /// Present when the query embeds the host's profile.
    var host: HostSummary?

    var hostName: String { host?.name ?? "Someone" }

    var coverURL: URL? {
        coverUrl.flatMap(URL.init(string:))
    }

    struct HostSummary: Codable, Equatable {
        var name: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, location, details, host
        case hostId = "host_id"
        case startsAt = "starts_at"
        case coverEmoji = "cover_emoji"
        case coverUrl = "cover_url"
        case inviteCode = "invite_code"
    }
}

/// What the app sends to create a party. The database fills in the id and invite code.
struct NewParty: Encodable {
    let hostId: UUID
    let name: String
    let startsAt: Date
    let location: String
    let details: String
    let coverEmoji: String
    /// Left out of the insert when nil, so emoji-only parties work before update 4 is run.
    let coverUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, location, details
        case hostId = "host_id"
        case startsAt = "starts_at"
        case coverEmoji = "cover_emoji"
        case coverUrl = "cover_url"
    }
}

/// What the app sends when the host edits a party.
struct PartyUpdate: Encodable {
    enum CoverURL {
        /// Left out of the update, so edits work before update 4 is run.
        case unchanged
        case set(String)
        case clear
    }

    let name: String
    let startsAt: Date
    let location: String
    let details: String
    let coverEmoji: String
    let coverUrl: CoverURL

    enum CodingKeys: String, CodingKey {
        case name, location, details
        case startsAt = "starts_at"
        case coverEmoji = "cover_emoji"
        case coverUrl = "cover_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(startsAt, forKey: .startsAt)
        try container.encode(location, forKey: .location)
        try container.encode(details, forKey: .details)
        try container.encode(coverEmoji, forKey: .coverEmoji)
        switch coverUrl {
        case .unchanged: break
        case .set(let url): try container.encode(url, forKey: .coverUrl)
        case .clear: try container.encodeNil(forKey: .coverUrl)
        }
    }
}

/// A party together with your RSVP for it.
struct PartyMembership: Codable, Identifiable, Equatable {
    var status: InviteStatus
    var party: Party

    var id: UUID { party.id }
}

/// Result row of the `party_going_counts` function.
struct GoingCount: Decodable {
    let partyId: UUID
    let goingCount: Int

    enum CodingKeys: String, CodingKey {
        case partyId = "party_id"
        case goingCount = "going_count"
    }
}

/// A like or a pass you made on someone at a party.
struct LikeRecord: Codable, Equatable {
    let partyId: UUID
    let fromUser: UUID
    let toUser: UUID
    let isLike: Bool

    enum CodingKeys: String, CodingKey {
        case partyId = "party_id"
        case fromUser = "from_user"
        case toUser = "to_user"
        case isLike = "is_like"
    }
}

/// Two people who liked each other at the same party.
struct Match: Codable, Identifiable, Equatable {
    let id: UUID
    let partyId: UUID
    let userA: UUID
    let userB: UUID
    let createdAt: Date
    // Present when the query embeds related rows.
    var party: PartySummary?
    var profileA: Profile?
    var profileB: Profile?
    var latestMessages: [Message]?

    struct PartySummary: Codable, Equatable {
        var name: String
    }

    /// The person in this match who isn't you.
    func otherProfile(for me: UUID) -> Profile? {
        userA == me ? profileB : profileA
    }

    func otherUserID(for me: UUID) -> UUID {
        userA == me ? userB : userA
    }

    var lastMessage: Message? { latestMessages?.first }

    /// True when the other person's latest message hasn't been read yet.
    func hasUnread(for me: UUID) -> Bool {
        guard let last = lastMessage else { return false }
        return last.senderId != me && last.readAt == nil
    }

    enum CodingKeys: String, CodingKey {
        case id, party
        case partyId = "party_id"
        case userA = "user_a"
        case userB = "user_b"
        case createdAt = "created_at"
        case profileA = "profile_a"
        case profileB = "profile_b"
        case latestMessages = "messages"
    }
}

struct Message: Codable, Identifiable, Equatable {
    let id: UUID
    let matchId: UUID
    let senderId: UUID
    var text: String
    let createdAt: Date
    var readAt: Date?

    /// Local-only state while a message is on its way to the server.
    var deliveryState: DeliveryState = .delivered

    enum DeliveryState: Equatable {
        case sending
        case delivered
        case failed
    }

    enum CodingKeys: String, CodingKey {
        case id, text
        case matchId = "match_id"
        case senderId = "sender_id"
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

struct NewMessage: Encodable {
    /// Generated on the phone so the optimistic copy and the server row share an id.
    let id: UUID
    let matchId: UUID
    let senderId: UUID
    let text: String

    enum CodingKeys: String, CodingKey {
        case id, text
        case matchId = "match_id"
        case senderId = "sender_id"
    }
}

/// Why someone is being reported. Stored as text so you can add reasons later.
enum ReportReason: String, CaseIterable, Identifiable {
    case fakeProfile = "Fake profile"
    case inappropriatePhotos = "Inappropriate photos"
    case harassment = "Harassment or hateful messages"
    case underage = "Seems under 18"
    case other = "Something else"

    var id: String { rawValue }
}

struct NewReport: Encodable {
    let reporterId: UUID
    let reportedId: UUID
    let partyId: UUID?
    let reason: String
    let details: String

    enum CodingKeys: String, CodingKey {
        case reason, details
        case reporterId = "reporter_id"
        case reportedId = "reported_id"
        case partyId = "party_id"
    }
}

struct NewBlock: Encodable {
    let blockerId: UUID
    let blockedId: UUID

    enum CodingKeys: String, CodingKey {
        case blockerId = "blocker_id"
        case blockedId = "blocked_id"
    }
}

struct DeviceTokenRecord: Encodable {
    let token: String
    let userId: UUID
    let platform: String

    enum CodingKeys: String, CodingKey {
        case token, platform
        case userId = "user_id"
    }
}
