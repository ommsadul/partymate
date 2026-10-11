import SwiftUI

/// Email sign-in. Supabase emails a link; opening it signs you in.
/// Laid out like Apple's welcome screens: centered intro, action pinned to the bottom.
struct SignInView: View {
    @Environment(AppStore.self) private var store

    @State private var email = ""
    @State private var didSendLink = false
    @State private var isWorking = false
    /// Drives the opening sequence: 0 before it starts, 1 once everything is in place.
    @State private var wordmarkProgress: Double = 0
    @State private var showsTagline = false
    @FocusState private var isEmailFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespaces)
    }

    private var isValidEmail: Bool {
        trimmedEmail.contains("@") && trimmedEmail.contains(".")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                intro
                    .padding(.top, 72)

                if didSendLink {
                    checkEmail
                } else {
                    emailEntry
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            bottomActions
        }
        .overlay {
            if isWorking {
                ProgressView()
            }
        }
    }

    /// The opening sequence: the rings slide together, then the letters of the name rise
    /// into place one after another, then the tagline fades in. Plays once.
    private var intro: some View {
        VStack(spacing: 16) {
            PartymateMark(size: 112, animatesIn: true)
                .padding(.bottom, 14)

            Text("partymate")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .tracking(-1.8)
                .textRenderer(LetterRiseRenderer(progress: wordmarkProgress))
                .accessibilityAddTraits(.isHeader)

            Text("Invite-only parties. Meet the people who are actually going.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .opacity(showsTagline ? 1 : 0)
                .offset(y: showsTagline ? 0 : 6)
        }
        .onAppear {
            guard wordmarkProgress == 0 else { return }
            if reduceMotion {
                wordmarkProgress = 1
                showsTagline = true
                return
            }
            // Overlaps the end of the rings meeting, so it reads as one motion.
            withAnimation(.easeOut(duration: 0.55).delay(0.3)) {
                wordmarkProgress = 1
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.65)) {
                showsTagline = true
            }
        }
    }

    private var emailEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($isEmailFocused)
                .onSubmit {
                    if isValidEmail { Task { await sendLink() } }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("We'll email you a sign-in link. No password needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Text(legalText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .tint(.primary)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
    }

    /// "By continuing, you agree to the Terms of Use and Privacy Policy", with links once set.
    private var legalText: AttributedString {
        func link(_ title: String, _ url: URL?) -> String {
            url.map { "[\(title)](\($0.absoluteString))" } ?? title
        }
        let markdown = "By continuing, you agree to the \(link("Terms of Use", SupabaseConfig.termsURL)) and \(link("Privacy Policy", SupabaseConfig.privacyPolicyURL))."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    private var checkEmail: some View {
        VStack(spacing: 10) {
            Text("✉️")
                .font(.system(size: 48))
            Text("Check your email")
                .font(.title2.bold())
            Text("We sent a sign-in link to \(trimmedEmail). Open it on this iPhone to continue.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var bottomActions: some View {
        VStack(spacing: 6) {
            if didSendLink {
                Button {
                    Task { await sendLink() }
                } label: {
                    Text("Send Again")
                        .frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()
                .disabled(isWorking)

                Button("Use a Different Email") {
                    didSendLink = false
                    isEmailFocused = true
                }
                .padding(.vertical, 8)
            } else {
                Button {
                    Task { await sendLink() }
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
                .disabled(!isValidEmail || isWorking)

                #if DEBUG
                Button("Skip Sign-In (Testing)") {
                    Task {
                        isWorking = true
                        defer { isWorking = false }
                        await store.signInForTesting()
                    }
                }
                .foregroundStyle(.secondary)
                .disabled(isWorking)
                .padding(.vertical, 8)
                #endif
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func sendLink() async {
        isWorking = true
        defer { isWorking = false }
        if await store.sendMagicLink(to: trimmedEmail) {
            didSendLink = true
        }
    }
}

/// Draws text one letter at a time: each letter fades in and rises a little, slightly after the
/// one before it. Keeps the font's own letter spacing. (No blur: it drops frames.)
private struct LetterRiseRenderer: TextRenderer, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let letters = layout.flatMap { $0 }.flatMap { $0 }
        let count = Double(max(letters.count, 1))
        // Each letter animates over half the time; their starts are spread across the rest.
        let span = 0.5
        for (index, letter) in letters.enumerated() {
            let start = Double(index) / count * (1 - span)
            let t = min(1, max(0, (progress - start) / span))
            let eased = 1 - pow(1 - t, 3)

            var copy = context
            copy.opacity = eased
            copy.translateBy(x: 0, y: (1 - eased) * 12)
            copy.draw(letter, options: .disablesSubpixelQuantization)
        }
    }
}

#Preview {
    SignInView()
        .environment(AppStore())
}
