import CCKit
import SwiftUI

struct CommandOutput: Identifiable {
    let command: String
    let output: String

    var id: String { "\(command)-\(output)" }
}

struct CommandOutputSheet: View {
    let command: String
    let output: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(.ccBackground)
            .navigationTitle(command)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct CommandModelSheet: View {
    let session: Session
    let loadModels: @MainActor () async throws -> [CommandModelOption]
    let onSelect: @MainActor (String) async -> Result<MessageResult, ActionError>
    @Environment(\.dismiss) private var dismiss
    @State private var models: [CommandModelOption] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectingID: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("model-loading")
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.ccSecondary)
                            .multilineTextAlignment(.center)
                        Button("Retry", action: load)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("model-error")
                } else {
                    List {
                        Section {
                            ForEach(models) { model in
                                Button {
                                    select(model)
                                } label: {
                                    HStack {
                                        Text(model.label)
                                            .foregroundStyle(.ccLabel)
                                        Spacer()
                                        if model.id == session.usage?.model {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.ccAccent)
                                                .accessibilityLabel("Current model")
                                        }
                                    }
                                }
                                .disabled(selectingID != nil)
                                .accessibilityIdentifier("model-option-\(model.id)")
                            }
                        } footer: {
                            Text("Also becomes your default for new sessions, as /model does in the terminal.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(.ccBackground)
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.ccAccent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { load() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @MainActor
    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                models = try await loadModels()
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    @MainActor
    private func select(_ model: CommandModelOption) {
        selectingID = model.id
        Task {
            switch await onSelect(model.id) {
            case .success:
                dismiss()
            case .failure:
                selectingID = nil
            }
        }
    }
}

struct CommandToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.ccLabel)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.thinMaterial, in: .capsule)
            .shadow(radius: 8, y: 3)
            .accessibilityIdentifier("command-toast")
            .padding(.bottom, 12)
    }
}
