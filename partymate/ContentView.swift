import SwiftUI

/// Root of the app. Shows sign-in, profile setup, or the main tabs depending on auth state.
struct ContentView: View {
    @State private var store = AppStore()

    var body: some View {
        @Bindable var store = store
        Group {
            if !SupabaseConfig.isConfigured {
                SetupNeededView()
            } else {
                switch store.authState {
                case .loading:
                    ProgressView("Loading…")
                case .signedOut:
                    SignInView()
                case .needsProfile:
                    NavigationStack {
                        ProfileFormView(mode: .setup)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                case .signedIn:
                    MainTabView()
                }
            }
        }
        .environment(store)
        .tint(.primary)
        .task {
            guard SupabaseConfig.isConfigured else { return }
            await store.observeSession()
        }
        .onOpenURL { url in
            store.handle(url: url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            // Universal links (https://yourdomain/join/CODE) arrive here.
            if let url = activity.webpageURL {
                store.handle(url: url)
            }
        }
        .onChange(of: store.authState) { _, newValue in
            if newValue == .signedIn {
                PushManager.shared.requestPermission()
            }
        }
        .onChange(of: PushManager.shared.deviceToken) { _, token in
            guard let token else { return }
            Task { await store.registerDeviceToken(token) }
        }
        .alert("Something went wrong", isPresented: $store.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
    }
}

private struct MainTabView: View {
    @Environment(AppStore.self) private var store

    private enum Tabs: Hashable {
        case parties, matches, profile
    }

    @State private var selectedTab = Tabs.parties

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Parties", systemImage: "party.popper", value: .parties) {
                PartiesListView()
            }
            Tab("Matches", systemImage: "heart", value: .matches) {
                MatchesListView()
            }
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
                ProfileTabView()
            }
        }
        .onChange(of: store.pendingPartyID) { _, newValue in
            // Jump to the Parties tab when an invite link opens a party.
            if newValue != nil {
                selectedTab = .parties
            }
        }
    }
}

/// Shown until the Supabase URL and key have been filled in.
private struct SetupNeededView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect to Supabase", systemImage: "key")
        } description: {
            Text("Open SupabaseConfig.swift and paste in your project URL and anon key. See SETUP.md for the full steps.")
        }
    }
}

#Preview {
    ContentView()
}
