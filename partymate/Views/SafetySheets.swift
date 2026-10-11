import SwiftUI

/// Report someone. Stored for you to review in the Supabase dashboard.
struct ReportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let userID: UUID
    let userName: String
    var partyID: UUID?
    /// Called after a successful report so the caller can also block, close the chat, etc.
    var onReported: (() -> Void)? = nil

    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { option in
                            Text(option.rawValue).tag(Optional(option))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("What's wrong with \(userName)'s profile?")
                }

                Section {
                    TextField("Add details (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("Reports are private. \(userName) won't know who reported them.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "checkmark") {
                        Task { await send() }
                    }
                    .disabled(reason == nil || isSending)
                }
            }
        }
    }

    private func send() async {
        guard let reason else { return }
        isSending = true
        defer { isSending = false }
        if await store.report(userID, reason: reason, details: details, partyID: partyID) {
            dismiss()
            onReported?()
        }
    }
}

/// Menu with Unmatch / Block / Report, used in the chat toolbar and on guest cards.
struct SafetyMenu: View {
    let userName: String
    var showsUnmatch: Bool
    let onUnmatch: () -> Void
    let onBlock: () -> Void
    let onReport: () -> Void

    var body: some View {
        Menu {
            if showsUnmatch {
                Button("Unmatch", systemImage: "heart.slash", action: onUnmatch)
            }
            Button("Block \(userName)", systemImage: "hand.raised", role: .destructive, action: onBlock)
            Button("Report \(userName)", systemImage: "flag", role: .destructive, action: onReport)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .accessibilityLabel("More Options")
    }
}
