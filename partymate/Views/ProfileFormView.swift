import SwiftUI
import PhotosUI

/// Create or edit your profile. This is what other guests see when they swipe on you.
/// Setup mode is the first-run screen; edit mode is presented in a sheet from the Profile tab.
struct ProfileFormView: View {
    enum Mode {
        /// First run: must be completed before using the app.
        case setup
        /// From the Profile tab's Edit Profile button.
        case edit
    }

    /// A photo slot: either already uploaded, or newly picked and waiting to upload.
    private enum PhotoSlot: Identifiable, Equatable {
        case uploaded(URL)
        case new(id: UUID, data: Data)

        var id: String {
            switch self {
            case .uploaded(let url): url.absoluteString
            case .new(let id, _): id.uuidString
            }
        }
    }

    /// Which part of the profile to show. `.all` is the full editor; the others open
    /// just one section, for the "Finish Your Profile" shortcuts.
    enum Focus: String, Identifiable {
        case all, photos, bio, instagram
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Edit Profile"
            case .photos: "Photos"
            case .bio: "About You"
            case .instagram: "Instagram"
            }
        }
    }

    static let bioLimit = 150

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var focus: Focus = .all

    private enum Field { case name, instagram, bio }
    @FocusState private var focusedField: Field?

    private func shows(_ section: Focus) -> Bool {
        focus == .all || focus == section
    }

    @State private var name = ""
    @State private var instagram = ""
    @State private var bio = ""
    @State private var photos: [PhotoSlot] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var hasLoadedExisting = false
    @State private var isSaving = false
    @State private var saveCount = 0

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedBio: String {
        bio.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanedInstagram: String? {
        let handle = instagram
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
        return handle.isEmpty ? nil : handle
    }

    private var isComplete: Bool {
        !photos.isEmpty && !trimmedName.isEmpty
    }

    /// True when something differs from the saved profile.
    private var hasChanges: Bool {
        guard let saved = store.currentProfile else { return true }
        return trimmedName != saved.name
            || trimmedBio != saved.bio
            || cleanedInstagram != (saved.instagram?.isEmpty == true ? nil : saved.instagram)
            || photos != saved.photoURLs.map(PhotoSlot.uploaded)
    }

    private var remainingSlots: Int {
        max(0, Profile.maxPhotos - photos.count)
    }

    var body: some View {
        Form {
            if mode == .setup {
                Section {
                    VStack(spacing: 8) {
                        Text("Set Up Your Profile")
                            .font(.title.bold())
                        Text("People only see this once you're both going to the same party.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }
                .listRowBackground(Color.clear)
            }

            if shows(.photos) {
                Section {
                    photoGrid
                        .padding(.vertical, 6)
                } header: {
                    if focus == .all { Text("Photos") }
                } footer: {
                    Text(focus == .photos
                         ? "Profiles with 3 or more photos get more likes. The first one is your main photo; touch and hold a photo to change it."
                         : "Add up to \(Profile.maxPhotos). The first one is your main photo. Touch and hold a photo to make it your main one.")
                }
            }

            if focus == .all {
                Section {
                    labeledField("Name") {
                        TextField("First name", text: $name)
                            .textContentType(.givenName)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .name)
                    }
                    labeledField("Instagram") { instagramField }
                } footer: {
                    Text("Only your matches see your Instagram.")
                }
            } else if focus == .instagram {
                Section {
                    instagramField
                } footer: {
                    Text("Only your matches see it, so they can find you after the party.")
                }
            }

            if shows(.bio) {
            Section {
                TextField("Something people can start a conversation with", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .bio)
                    .onChange(of: bio) { _, newValue in
                        if newValue.count > Self.bioLimit {
                            bio = String(newValue.prefix(Self.bioLimit))
                        }
                    }
            } header: {
                if focus == .all { Text("About") }
            } footer: {
                HStack(alignment: .top) {
                    if focus == .bio {
                        Text("Try a fun fact, what you're into, or what to ask you about.")
                    }
                    Spacer()
                    Text("\(bio.count)/\(Self.bioLimit)")
                        .monospacedDigit()
                }
            }
            }

            if mode == .setup {
                Section {
                    ActionBlock(note: isComplete ? nil : (photos.isEmpty ? "Add at least one photo to continue." : "Add your name to continue.")) {
                        Button {
                            Task { await save() }
                        } label: {
                            ButtonText("Continue")
                        }
                        .prominentActionStyle()
                        .disabled(!isComplete || isSaving)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if mode == .edit {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", systemImage: "checkmark") {
                            Task { await save() }
                        }
                        .disabled(!hasChanges || !isComplete)
                    }
                }
            }
        }
        .interactiveDismissDisabled(mode == .edit && hasChanges)
        .overlay {
            if isSaving && mode == .setup {
                ProgressView()
            }
        }
        .sensoryFeedback(.success, trigger: saveCount)
        .task {
            // Fill the form once from the saved profile, if there is one.
            guard !hasLoadedExisting else { return }
            hasLoadedExisting = true
            if let profile = store.currentProfile {
                name = profile.name
                instagram = profile.instagram ?? ""
                bio = profile.bio
                photos = profile.photoURLs.map(PhotoSlot.uploaded)
            }
        }
        .onAppear {
            switch focus {
            case .bio: focusedField = .bio
            case .instagram: focusedField = .instagram
            default: break
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(from: items) }
        }
    }

    private var instagramField: some View {
        HStack(spacing: 1) {
            Text("@")
                .foregroundStyle(.secondary)
            TextField("username", text: $instagram)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedField, equals: .instagram)
        }
    }

    /// A Contacts-style row: label on the left, field on the right.
    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 92, alignment: .leading)
            field()
        }
    }

    /// Six slots, like Hinge: your photos first, then empty slots that open the photo picker.
    private var photoGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(0..<Profile.maxPhotos, id: \.self) { index in
                if index < photos.count {
                    let slot = photos[index]
                    PhotoTile(slot: slot, isMain: index == 0) {
                        remove(slot)
                    }
                    .contextMenu {
                        if index > 0 {
                            Button("Make Main Photo", systemImage: "star") {
                                makeMain(slot)
                            }
                        }
                        Button("Remove Photo", systemImage: "trash", role: .destructive) {
                            remove(slot)
                        }
                    }
                } else {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: remainingSlots, matching: .images) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(index == photos.count ? .title2.weight(.semibold) : .body)
                                    .foregroundStyle(index == photos.count ? .secondary : .tertiary)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Photo")
                }
            }
        }
    }

    private func remove(_ slot: PhotoSlot) {
        withAnimation(.snappy) {
            photos.removeAll { $0.id == slot.id }
        }
    }

    private func makeMain(_ slot: PhotoSlot) {
        withAnimation(.snappy) {
            photos.removeAll { $0.id == slot.id }
            photos.insert(slot, at: 0)
        }
    }

    private func addPhotos(from items: [PhotosPickerItem]) async {
        for item in items {
            guard photos.count < Profile.maxPhotos else { break }
            if let data = try? await item.loadTransferable(type: Data.self),
               let jpeg = ImageProcessing.jpegForUpload(data) {
                photos.append(.new(id: UUID(), data: jpeg))
            }
        }
        pickerItems = []
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        // Upload anything new, keeping the user's order.
        var urls: [URL] = []
        for slot in photos {
            switch slot {
            case .uploaded(let url):
                urls.append(url)
            case .new(_, let data):
                guard let uploaded = await store.uploadPhoto(data) else { return }
                urls.append(uploaded)
            }
        }

        await store.saveProfile(
            name: trimmedName,
            bio: trimmedBio,
            instagram: cleanedInstagram,
            photoURLs: urls
        )
        photos = urls.map(PhotoSlot.uploaded)
        saveCount += 1
        if mode == .edit {
            dismiss()
        }
    }

    /// One photo in the grid with a remove button and a "Main" badge on the first.
    private struct PhotoTile: View {
        let slot: PhotoSlot
        let isMain: Bool
        let onRemove: () -> Void

        var body: some View {
            ZStack(alignment: .topTrailing) {
                // A fixed 3:4 frame with the photo filling it. Sizing the photo itself
                // with aspectRatio lets wide images spill out of their grid cell.
                Color.clear
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay {
                        photo
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if isMain {
                            Text("Main")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                    }

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Remove Photo")
            }
        }

        @ViewBuilder
        private var photo: some View {
            switch slot {
            case .uploaded(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemFill)
                    }
                }
            case .new(_, let data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemFill)
                }
            }
        }
    }
}

/// The Profile tab, laid out like Settings and the Contacts "My Card": an account row,
/// your photos, Contacts-style info rows that each open just that field, then settings.
struct ProfileTabView: View {
    @Environment(AppStore.self) private var store

    /// The editor being shown: the full one, or a single field.
    @State private var editing: ProfileFormView.Focus?
    @State private var isPreviewing = false
    @State private var isConfirmingDelete = false

    private var profile: Profile? { store.currentProfile }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            List {
                if let profile {
                    accountSection(profile)
                    photosSection(profile)
                    infoSection(profile)
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await store.signOut() }
                    }
                    Button("Delete Account", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    // The one action that keeps a confirmation: it erases everything for good.
                    .confirmationDialog("Delete your account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                        Button("Delete Account", role: .destructive) {
                            Task { _ = await store.deleteAccount() }
                        }
                    } message: {
                        Text("Your profile, photos, parties you host, matches, and chats are permanently deleted.")
                    }
                }

                if SupabaseConfig.termsURL != nil || SupabaseConfig.privacyPolicyURL != nil {
                    Section {
                        if let url = SupabaseConfig.termsURL {
                            Link("Terms of Use", destination: url)
                        }
                        if let url = SupabaseConfig.privacyPolicyURL {
                            Link("Privacy Policy", destination: url)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                } footer: {
                    Text("partymate \(appVersion)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Profile")
            .toolbarTitleDisplayMode(.inlineLarge)
            .task {
                // The account row shows match and party counts.
                await store.loadMatches()
            }
            .toolbar {
                if profile != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") {
                            editing = .all
                        }
                    }
                }
            }
            .sheet(item: $editing) { focus in
                NavigationStack {
                    ProfileFormView(mode: .edit, focus: focus)
                        .navigationTitle(focus.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents(focus == .bio || focus == .instagram ? [.medium] : [.large])
            }
            .sheet(isPresented: $isPreviewing) {
                if let profile {
                    ProfilePreviewSheet(profile: profile)
                }
            }
        }
    }

    // MARK: - Sections

    /// Like the Apple Account row at the top of Settings.
    private func accountSection(_ profile: Profile) -> some View {
        Section {
            HStack(spacing: 16) {
                AvatarView(url: profile.avatarURL, size: 68)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.title2.weight(.semibold))
                    Text(memberSince)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private var memberSince: String {
        let going = store.goingParties.count
        let matches = store.matches.count
        let parties = going == 1 ? "1 party" : "\(going) parties"
        let people = matches == 1 ? "1 match" : "\(matches) matches"
        return "\(parties), \(people)"
    }

    /// Your photos in a row, like an album strip. Tap one to preview your card; + opens the photo editor.
    private func photosSection(_ profile: Profile) -> some View {
        let photos = profile.photoURLs
        return Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, url in
                        Button {
                            isPreviewing = true
                        } label: {
                            Color.clear
                                .frame(width: 84, height: 112)
                                .overlay {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Color(.secondarySystemFill)
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(index == 0 ? "Main photo" : "Photo \(index + 1)")
                    }

                    if photos.count < Profile.maxPhotos {
                        Button {
                            editing = .photos
                        } label: {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                                .frame(width: 84, height: 112)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add Photos")
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        } header: {
            HStack {
                Text("Photos")
                Spacer()
                Text("\(photos.count) of \(Profile.maxPhotos)")
            }
        } footer: {
            if photos.count < 3 {
                Text("Profiles with 3 or more photos get more likes.")
            }
        }
    }

    /// Contacts-style rows: a small label over the value. Empty values show what to add.
    private func infoSection(_ profile: Profile) -> some View {
        let bio = profile.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let instagram = profile.instagram.flatMap { $0.isEmpty ? nil : "@\($0)" }
        return Section {
            Button {
                editing = .bio
            } label: {
                InfoRow(label: "About", value: bio.isEmpty ? nil : bio, placeholder: "Add a line about yourself")
            }
            Button {
                editing = .instagram
            } label: {
                InfoRow(label: "Instagram", value: instagram, placeholder: "Add your Instagram")
            }
        } footer: {
            Text("Only your matches see your Instagram.")
        }
    }
}

/// A Contacts-style row: small label on top, the value below, chevron on the right.
private struct InfoRow: View {
    let label: String
    let value: String?
    let placeholder: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value ?? placeholder)
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

#Preview {
    ProfileFormView(mode: .setup)
        .environment(AppStore())
}
