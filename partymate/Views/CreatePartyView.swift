import SwiftUI
import PhotosUI

/// Host a new party, or edit one you're hosting. You're automatically on the guest list.
struct CreatePartyView: View {
    private enum CoverKind: String, CaseIterable {
        case emoji = "Emoji"
        case photo = "Photo"
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The party being edited, or nil when creating a new one.
    private let editing: Party?
    /// Called after the party is deleted and this sheet has closed.
    private let onDeleted: (() -> Void)?

    @State private var name: String
    @State private var startsAt: Date
    @State private var location: String
    @State private var details: String
    @State private var coverEmoji: String
    @State private var coverKind: CoverKind
    /// A newly picked photo, waiting to upload.
    @State private var coverPhoto: Data?
    /// The photo the party already has, when editing.
    @State private var existingPhotoURL: URL?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var isPickingEmoji = false
    @State private var isSaving = false

    init(editing party: Party? = nil, onDeleted: (() -> Void)? = nil) {
        editing = party
        self.onDeleted = onDeleted
        _name = State(initialValue: party?.name ?? "")
        _startsAt = State(initialValue: party?.startsAt ?? Self.defaultStart)
        _location = State(initialValue: party?.location ?? "")
        _details = State(initialValue: party?.details ?? "")
        _coverEmoji = State(initialValue: party?.coverEmoji ?? "🎉")
        _existingPhotoURL = State(initialValue: party?.coverURL)
        _coverKind = State(initialValue: party?.coverURL == nil ? .emoji : .photo)
    }

    /// New parties start tomorrow at 8:00 PM, not at an arbitrary minute.
    private static var defaultStart: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private var isEditing: Bool { editing != nil }

    private var hasPhoto: Bool {
        coverPhoto != nil || existingPhotoURL != nil
    }

    /// Quick picks. "More" opens the full emoji keyboard for anything else.
    private let emojiChoices = ["🎉", "🎂", "🥂", "🍻", "🪩", "🎶", "🎤", "🔥", "🌇", "🏖️", "🏠", "🍕", "🌮", "🎮", "🎃", "🎄", "🎈"]

    private var coverImage: UIImage? {
        guard coverKind == .photo, let coverPhoto else { return nil }
        return UIImage(data: coverPhoto)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        coverPreview

                        Picker("Cover", selection: $coverKind) {
                            ForEach(CoverKind.allCases, id: \.self) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch coverKind {
                        case .emoji:
                            emojiGrid
                        case .photo:
                            PhotosPicker(selection: $coverPickerItem, matching: .images) {
                                Label(hasPhoto ? "Change Photo" : "Choose Photo", systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background {
                        EmojiKeyboardField(emoji: $coverEmoji, isActive: $isPickingEmoji)
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                            .accessibilityHidden(true)
                    }
                }

                Section {
                    TextField("Party Name", text: $name)
                    TextField("Location", text: $location)
                }

                Section {
                    DatePicker("Starts", selection: $startsAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                }

                Section("Details") {
                    TextField("What should people know?", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }

                if isEditing {
                    Section {
                        Button("Delete Party", role: .destructive) {
                            Task { await delete() }
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("Removes the party for everyone, including its matches and chats.")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: coverPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = ImageProcessing.jpegForUpload(data) {
                        coverPhoto = jpeg
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Party" : "New Party")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(isEditing ? "Save" : "Create", systemImage: "checkmark") {
                            Task { await save() }
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
    }

    /// Big preview of the cover. Tapping the emoji opens the full emoji keyboard.
    @ViewBuilder
    private var coverPreview: some View {
        if let coverImage {
            Image(uiImage: coverImage)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .accessibilityLabel("Cover photo")
        } else if coverKind == .photo, let existingPhotoURL {
            PartyCover(emoji: coverEmoji, photoURL: existingPhotoURL, size: 120)
                .accessibilityLabel("Cover photo")
        } else if coverKind == .photo {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        } else {
            Button {
                isPickingEmoji = true
            } label: {
                EmojiTile(emoji: coverEmoji, size: 120)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cover emoji \(coverEmoji). Choose another")
        }
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
            ForEach(emojiChoices, id: \.self) { emoji in
                Button {
                    coverEmoji = emoji
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(
                            emoji == coverEmoji ? Color(.tertiarySystemFill) : .clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji)
                .accessibilityAddTraits(emoji == coverEmoji ? .isSelected : [])
            }

            Button {
                isPickingEmoji = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More Emoji")
        }
    }

    private func save() async {
        if let editing {
            await saveEdits(to: editing)
        } else {
            await create()
        }
    }

    private func saveEdits(to party: Party) async {
        isSaving = true
        defer { isSaving = false }

        let photo: AppStore.CoverPhotoChange
        switch coverKind {
        case .photo:
            if let coverPhoto {
                photo = .replace(coverPhoto)
            } else {
                photo = .keep
            }
        case .emoji:
            // Switching back to Emoji drops the old photo.
            photo = party.coverURL == nil ? .keep : .remove
        }

        let saved = await store.updateParty(
            party.id,
            name: trimmedName,
            startsAt: startsAt,
            location: location.trimmingCharacters(in: .whitespaces),
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            coverEmoji: coverEmoji,
            photo: photo
        )
        if saved {
            dismiss()
        }
    }

    private func delete() async {
        guard let editing else { return }
        isSaving = true
        defer { isSaving = false }
        if await store.deleteParty(editing.id) {
            dismiss()
            onDeleted?()
        }
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        let partyID = await store.createParty(
            name: trimmedName,
            startsAt: startsAt,
            location: location.trimmingCharacters(in: .whitespaces),
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            coverEmoji: coverEmoji,
            coverPhoto: coverKind == .photo ? coverPhoto : nil
        )
        if let partyID {
            dismiss()
            store.pendingPartyID = partyID
        }
    }
}

#Preview {
    CreatePartyView()
        .environment(AppStore())
}
