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
    let loadModels: @MainActor () async throws -> [ModelOption]
    let onSelect: @MainActor (String) async -> Result<MessageResult, ActionError>
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ModelOption] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectionError: String?
    @State private var selectingID: String?

    private var currentModelID: String? {
        matchingCommandModelID(options: models, usageModel: session.usage?.model)
    }

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
                                        if model.id == currentModelID {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.ccAccent)
                                                .accessibilityLabel("Current model")
                                                .accessibilityIdentifier("current-model-\(model.id)")
                                        }
                                    }
                                }
                                .disabled(selectingID != nil)
                                .accessibilityIdentifier("model-option-\(model.id)")
                            }
                            if let selectionError {
                                Text(selectionError)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("model-selection-error")
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
        selectionError = nil
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
    private func select(_ model: ModelOption) {
        selectingID = model.id
        selectionError = nil
        Task {
            switch await onSelect(model.id) {
            case .success:
                dismiss()
            case .failure(let error):
                selectingID = nil
                selectionError = error.userMessage
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
    }
}
