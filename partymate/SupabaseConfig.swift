import Foundation
import Supabase

/// Connection details for your Supabase project.
/// Find both values in the Supabase dashboard under Project Settings > API, and put them in SupabaseSecrets.swift.
enum SupabaseConfig {
    // The real values live in SupabaseSecrets.swift, which is never committed (see SETUP.md).
    static let projectURLString = SupabaseSecrets.projectURL
    static let anonKey = SupabaseSecrets.anonKey

    /// Where the sign-in email sends people back to. This exact value is also
    /// registered in Supabase under Authentication > URL Configuration > Redirect URLs.
    static let loginRedirectURLString = "partymate://login-callback"

    /// Your website, once you have one, e.g. "https://partymate.app".
    /// When set, invite links use it so they open from iMessage and work without the app installed.
    /// Leave nil until the domain is set up (see SETUP.md, "Invite links").
    static let webBaseURLString: String? = nil

    /// Public web pages for your Terms of Use and Privacy Policy. The App Store requires both
    /// for an app like this. Drafts are in docs/; host them anywhere public and paste the links here.
    static let termsURLString: String? = nil
    static let privacyPolicyURLString: String? = nil

    static var termsURL: URL? { termsURLString.flatMap(URL.init(string:)) }
    static var privacyPolicyURL: URL? { privacyPolicyURLString.flatMap(URL.init(string:)) }

    /// False until the placeholders above have been replaced.
    static var isConfigured: Bool {
        !projectURLString.contains("YOUR-PROJECT-REF") && !anonKey.contains("YOUR-ANON-KEY")
    }
}

/// The single shared connection to Supabase.
enum Backend {
    static let client: SupabaseClient = {
        guard let url = URL(string: SupabaseConfig.projectURLString) else {
            preconditionFailure("SupabaseConfig.projectURLString is not a valid URL")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: SupabaseConfig.anonKey)
    }()

    static var loginRedirectURL: URL? {
        URL(string: SupabaseConfig.loginRedirectURLString)
    }

    /// Builds the link a host shares so friends can join a party.
    static func inviteURL(code: String) -> URL? {
        if let web = SupabaseConfig.webBaseURLString {
            return URL(string: "\(web)/join/\(code)")
        }
        return URL(string: "partymate://join/\(code)")
    }

    /// Pulls the invite code out of either link form, or nil if the URL isn't an invite.
    static func inviteCode(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "partymate", url.host == "join", let code = parts.first {
            return code
        }
        if url.scheme == "https", parts.count >= 2, parts[0] == "join" {
            return parts[1]
        }
        return nil
    }
}
