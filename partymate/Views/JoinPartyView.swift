import SwiftUI

/// Join a party by typing the code from an invite.
struct JoinPartyView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isJoining = false
    @FocusState private var isCodeFocused: Bool

    private var cleanedCode: String {
        code.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private var canJoin: Bool {
        cleanedCode.count >= 4 && !isJoining
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite Code", text: $code)
                        .font(.title3.weight(.semibold))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.join)
                        .focused($isCodeFocused)
                        .onSubmit {
                            if canJoin { Task { await join() } }
                        }
                } footer: {
                    Text("The host can find the code on the party page. Opening an invite link also works.")
                }
            }
            .navigationTitle("Join Party")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", systemImage: "checkmark") {
                        Task { await join() }
                    }
                    .disabled(!canJoin)
                }
            }
            .onAppear {
                isCodeFocused = true
            }
        }
    }

    private func join() async {
        isJoining = true
        defer { isJoining = false }
        if await store.joinParty(code: cleanedCode) != nil {
            dismiss()
        }
    }
}

#Preview {
    JoinPartyView()
        .environment(AppStore())
}
