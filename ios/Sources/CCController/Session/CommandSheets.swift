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
    /// What the list's footer says picking a model does, which depends on the controller.
    var footer = "Also becomes your default for new sessions, as /model does in the terminal."
    let onSelect: @MainActor (String) async -> Result<Void, ActionError>
    /// Nil when the controller has no effort levels; the Effort row is then left out.
    var loadEfforts: (@MainActor () async throws -> [EffortOption])?
    var onSelectEffort: @MainActor (String) async -> Result<Void, ActionError> = { _ in .success(()) }
    @Environment(\.dismiss) private var dismiss
    @State private var efforts: [EffortOption] = []
    @State private var models: [ModelOption] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectionError: String?
    @State private var selectingID: String?

    private var currentModelID: String? {
        // A model picked for this session wins, since the transcript shows the old one until the next turn.
        if let picked = session.model, let option = models.first(where: { $0.id.caseInsensitiveCompare(picked) == .orderedSame }) {
            return option.id
        }
        return matchingCommandModelID(options: models, usageModel: session.model ?? session.usage?.model)
    }

    /// The session's own level, or "Default" with the level its model then runs at: "Default (Medium)".
    private var currentEffortText: String {
        if !isDefaultEffort(session.effort) {
            return effortLabel(session.effort, options: efforts) ?? "Default"
        }
        let modelDefault = sessionEffortName(
            effort: nil,
            modelID: currentModelID ?? session.usage?.model,
            models: models,
            efforts: efforts
        )
        return modelDefault.map { "Default (\($0))" } ?? "Default"
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
                            Text(footer)
                        }
                        if !efforts.isEmpty {
                            Section {
                                NavigationLink {
                                    CommandEffortList(
                                        efforts: effortOptions(efforts, forModel: currentModelID, models: models),
                                        currentID: isDefaultEffort(session.effort) ? defaultEffortID : session.effort,
                                        onSelect: onSelectEffort,
                                        onDone: { dismiss() }
                                    )
                                } label: {
                                    LabeledContent("Effort", value: currentEffortText)
                                }
                                .accessibilityIdentifier("model-effort")
                            }
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
                // The model list stands without the effort levels; a failure there only leaves the row out.
                efforts = (try? await loadEfforts?()) ?? []
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
                // The controller keeps a working session's model; the switch waits for the turn to end.
                selectionError = error == .sessionBusy
                    ? "Still working on this turn, so it keeps its model. Try again when it's done."
                    : error.userMessage
            }
        }
    }
}

/// The effort levels a session can run at, lowest first, with the current one ticked.
private struct CommandEffortList: View {
    let efforts: [EffortOption]
    let currentID: String?
    let onSelect: @MainActor (String) async -> Result<Void, ActionError>
    let onDone: @MainActor () -> Void
    @State private var selectingID: String?
    @State private var selectionError: String?

    var body: some View {
        List {
            Section {
                ForEach(efforts) { effort in
                    Button {
                        select(effort)
                    } label: {
                        HStack {
                            Text(effort.label)
                                .foregroundStyle(.ccLabel)
                            Spacer()
                            if effort.id.caseInsensitiveCompare(currentID ?? "") == .orderedSame {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.ccAccent)
                                    .accessibilityLabel("Current effort")
                                    .accessibilityIdentifier("current-effort-\(effort.id)")
                            }
                        }
                    }
                    .disabled(selectingID != nil)
                    .accessibilityIdentifier("effort-option-\(effort.id)")
                }
                if let selectionError {
                    Text(selectionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("effort-selection-error")
                }
            } footer: {
                Text("How hard this session thinks before it answers. Only this session. A running session rests and picks the new level up with your next message.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.ccBackground)
        .navigationTitle("Effort")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func select(_ effort: EffortOption) {
        selectingID = effort.id
        selectionError = nil
        Task {
            switch await onSelect(effort.id) {
            case .success:
                onDone()
            case .failure(let error):
                selectingID = nil
                selectionError = error == .sessionBusy
                    ? "Still working on this turn, so it keeps its effort. Try again when it's done."
                    : error.userMessage
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
