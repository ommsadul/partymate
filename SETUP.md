# partymate setup

Steps marked ✅ are already done for this project. The rest are what's left.

## ✅ 1. Supabase library in Xcode
Added via File > Add Package Dependencies (`https://github.com/supabase/supabase-swift`), product **Supabase** linked to the **partymate** target.

## ✅ 2. Database
`supabase/schema.sql` has been run in the Supabase SQL Editor.

## ✅ 3. Keys
The project URL and anon key live in `partymate/SupabaseSecrets.swift`, which git ignores so they never reach GitHub.

On a fresh clone, create it from the template:

```
cp SupabaseSecrets.example.swift partymate/SupabaseSecrets.swift
```

then fill in both values from the Supabase dashboard (Project Settings → API).

Also turn on the safety check that blocks commits containing keys (the repo is public):

```
git config core.hooksPath .githooks
```

## 4. Database updates (run once each, in order)

Supabase dashboard → **SQL Editor** → **New query** → paste the whole file → **Run**.

| File | Adds |
|---|---|
| `supabase/02-profile-photos.sql` | Profile photos + Instagram column, `avatars` storage bucket |
| `supabase/03-social.sql` | Multiple photos, block / report / unmatch, read receipts, "leaving a party removes your matches", device tokens for push |
| `supabase/04-party-covers.sql` | Optional cover photo for a party, shown instead of its emoji |
| `supabase/05-delete-account.sql` | Lets people delete their account from the Profile tab (required by the App Store) |

All are safe to run more than once.

### Demo data (for testing)

`supabase/seed-demo.sql` fills the app with 24 fake people, parties you host and attend, invitations, likes, and chats, for the account that signed in most recently. Run it after signing in and finishing your profile. `supabase/remove-demo.sql` deletes all of it. Both are safe to run more than once.

## ✅ 5. Email sign-in
`partymate://login-callback` is registered under Authentication → URL Configuration → Redirect URLs.

Sign-in emails contain a link only. On a real phone, tapping it opens the app. In the simulator, paste the link into the chat and Claude opens it there (`xcrun simctl openurl booted "<link>"`), then tap **Open** in Safari's prompt.

Supabase's built-in email sending is limited to a few messages per hour. Before launch, connect a custom email provider (Authentication → SMTP Settings) to lift the limit and brand the emails.

## 6. Invite links that work from iMessage (needs a domain)

Today invites are `partymate://join/CODE`. iMessage doesn't make those tappable. The fix is a normal web link, e.g. `https://partymate.app/join/K7M2PQ`, which opens the app if installed and otherwise shows a web page.

1. Buy a domain (Namecheap, Cloudflare, etc.).
2. Host a static file at `https://YOUR-DOMAIN/.well-known/apple-app-site-association` (no file extension, served as `application/json`):
   ```json
   {
     "applinks": {
       "details": [
         { "appIDs": ["TEAMID.your.bundle.id"], "components": [{ "/": "/join/*" }] }
       ]
     }
   }
   ```
   `TEAMID` is your Apple Developer Team ID; the bundle id is in Xcode under the target's General tab.
3. Also host a tiny page at `/join/*` that says "Get partymate" with an App Store link, for people without the app.
4. In Xcode: target **partymate** → **Signing & Capabilities** → **+ Capability** → **Associated Domains** → add `applinks:YOUR-DOMAIN`. (Needs a paid Apple Developer account.)
5. In `SupabaseConfig.swift`, set `webBaseURLString = "https://YOUR-DOMAIN"`.

The app already handles both link forms, so nothing else changes.

## 7. Push notifications (needs a paid Apple Developer account)

The app already asks for permission and saves the device token. The server side is the Edge Function in `supabase/functions/send-push`.

1. **Apple:** [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles → **Keys** → **+** → tick **Apple Push Notifications service (APNs)** → download the `.p8` file. Note the **Key ID** and your **Team ID**.
2. **Xcode:** target **partymate** → **Signing & Capabilities** → **+ Capability** → **Push Notifications**.
3. **Supabase CLI** (one-time): `brew install supabase/tap/supabase`, then in the project folder:
   ```
   supabase login
   supabase link --project-ref YOUR-PROJECT-REF
   supabase functions deploy send-push
   supabase secrets set APNS_TEAM_ID=XXXXXXXXXX APNS_KEY_ID=XXXXXXXXXX APNS_BUNDLE_ID=your.bundle.id APNS_ENVIRONMENT=sandbox
   supabase secrets set APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
   ```
4. **Supabase dashboard** → **Database** → **Webhooks** → create two webhooks that call the `send-push` function:
   - table `messages`, event **Insert**
   - table `matches`, event **Insert**
5. Run the app on a **real iPhone** (the simulator can't receive real pushes). Accept the notification prompt.

Switch `APNS_ENVIRONMENT` to `production` for TestFlight / App Store builds.

## 8. Run

Press ⌘R. Sign in with your email, add photos and a name, create a party, share the code.

To test matching: Profile tab → **Sign out**, sign in with a second email (a Gmail alias like `you+friend@gmail.com` works), join with the code, accept, and like each other.

## 9. Publish to the App Store

The app side is ready: app icon, privacy manifest, account deletion, iPhone-only portrait layout, iOS 26+, and the testing sign-in button only exists in debug builds. What's left needs your accounts.

### Before you build
1. **Apple Developer Program** ($99/year): [developer.apple.com/programs](https://developer.apple.com/programs).
2. **Bundle ID:** Xcode → target **partymate** → **Signing & Capabilities** → pick your **Team**, then replace the placeholder bundle identifier with your own (e.g. `com.yourname.partymate`).
3. **Run `supabase/05-delete-account.sql`** (and `04-party-covers.sql` if you haven't).
4. **Host the Terms and Privacy Policy:** fill in the drafts in `docs/`, publish them anywhere public (Notion, GitHub Pages, your site), and paste the links into `SupabaseConfig.swift` (`termsURLString`, `privacyPolicyURLString`). They then show on the sign-in screen and in Profile.

### Supabase, before real users
5. **Turn off anonymous sign-ins** (Authentication → Sign In / Providers).
6. **Custom email (SMTP)**, otherwise only a few sign-in emails go out per hour (Authentication → SMTP Settings).
7. **Remove the demo data:** run `supabase/remove-demo.sql`.
8. **Review sign-in:** Apple's reviewers must be able to sign in, and they can't open your emailed link. Set this up before submitting (see the open question in the chat / ask Claude).

### Build and upload
9. Xcode → scheme destination **Any iOS Device** → **Product → Archive** → **Distribute App → App Store Connect → Upload**.
10. In [App Store Connect](https://appstoreconnect.apple.com): create the app, fill in the listing from `docs/app-store-listing.md`, answer App Privacy to match it, set the age rating to 18+, add screenshots (6.9" iPhone), and add review notes.
11. Test the uploaded build with **TestFlight** on a real iPhone, then **Submit for Review**.

### Optional for 1.0
- Push notifications (section 7) and iMessage-friendly invite links (section 6) both need the paid account; the app works without them.
