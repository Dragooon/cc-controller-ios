import CCKit
import SwiftUI

/// A controller the New Session sheet can start a session on.
struct NewSessionControllerChoice: Identifiable, Equatable {
    let id: ControllerID
    let name: String
}

struct NewSessionView: View {
    let store: AppStore
    var controllerChoices: [NewSessionControllerChoice] = []
    var selectedControllerID: Binding<ControllerID>? = nil
    let onCreated: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool

    @State private var options: NewSessionOptions?
    @State private var loading = true
    @State private var loadError: String?
    @State private var createError: String?
    @State private var selectedFolderPath: String?
    @State private var selectedAgentID: String?
    @State private var prompt = ""
    @State private var isCreating = false
    @State private var customFolderDraft = ""
    @State private var isCustomFolderPresented = false

    private static let lastControllerKey = "newSession.lastControllerID"
    private static let folderKeyPrefix = "newSession.folder."
    private static let agentKeyPrefix = "newSession.agent."

    private var currentControllerID: ControllerID {
        selectedControllerID?.wrappedValue ?? .mac
    }

    private var stockadeAgents: [NewSessionAgent]? {
        options?.agents
    }

    private var claudeAgents: [ClaudeAgentOption]? {
        options?.claudeAgents
    }

    private var isStockade: Bool {
        options?.agents != nil
    }

    private var canCreate: Bool {
        guard let options, !loading, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isStockade { return selectedAgentID?.isEmpty == false }
        return selectedFolderPath != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextField("What do you want to work on?", text: $prompt, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.sentences)
                    .focused($promptFocused)
                    .accessibilityIdentifier("new-session-prompt")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
            }
            .background(.ccBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if let message = loadError ?? createError {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("new-session-error")
                            if loadError != nil {
                                Button("Retry", action: loadOptions)
                                    .font(.footnote.weight(.semibold))
                                    .accessibilityIdentifier("new-session-retry")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    controls
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.ccBackground)
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
            }
            .tint(.ccAccent)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            selectInitialController()
            loadOptions()
            focusPrompt()
        }
        .onChange(of: selectedControllerID?.wrappedValue) { _, _ in
            loadOptions()
        }
        .sheet(isPresented: $isCustomFolderPresented) {
            customFolderSheet
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if controllerChoices.count >= 2 {
                        hostMenu
                    }
                    if loading {
                        loadingChip
                    } else if !isStockade {
                        folderMenu
                    }
                    if loading {
                        loadingChip
                    } else if isStockade, stockadeAgents?.isEmpty == false {
                        stockadeAgentMenu
                    } else if !isStockade, claudeAgents?.isEmpty == false {
                        claudeAgentMenu
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            sendButton
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .disabled(isCreating)
    }

    private var loadingChip: some View {
        ProgressView()
            .controlSize(.small)
            .frame(minWidth: 44, minHeight: 36)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("new-session-loading")
    }

    private var hostMenu: some View {
        Menu {
            ForEach(controllerChoices) { choice in
                Button {
                    selectedControllerID?.wrappedValue = choice.id
                } label: {
                    Text(choice.name)
                }
            }
        } label: {
            chipLabel(systemImage: "desktopcomputer", text: controllerChoices.first(where: { $0.id == currentControllerID })?.name ?? "Host")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-session-host")
    }

    private var folderMenu: some View {
        Menu {
            ForEach(options?.folders ?? []) { folder in
                Button {
                    selectedFolderPath = folder.path
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folderLastComponent(folder.path))
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("new-session-folder-\(folder.name)")
            }
            if let selectedFolderPath, !(options?.folders.contains(where: { $0.path == selectedFolderPath }) ?? false) {
                Button {
                    self.selectedFolderPath = selectedFolderPath
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folderLastComponent(selectedFolderPath))
                        Text(selectedFolderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Button("Other folder…", systemImage: "folder.badge.plus") {
                customFolderDraft = ""
                Task { @MainActor in
                    await Task.yield()
                    isCustomFolderPresented = true
                }
            }
        } label: {
            chipLabel(systemImage: "folder", text: selectedFolderPath.map(folderLastComponent) ?? "Folder")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-session-folder")
    }

    private var stockadeAgentMenu: some View {
        Menu {
            ForEach(stockadeAgents ?? []) { agent in
                Button {
                    selectedAgentID = agent.id
                } label: {
                    Text(agent.name)
                }
                .accessibilityIdentifier("new-session-agent-\(agent.id)")
            }
        } label: {
            chipLabel(systemImage: "person", text: selectedAgentName ?? "Agent")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-session-agent")
    }

    private var claudeAgentMenu: some View {
        Menu {
            ForEach(claudeAgents ?? []) { agent in
                Button {
                    selectedAgentID = agent.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.label)
                        if let description = agent.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("new-session-agent-\(agent.id)")
            }
        } label: {
            chipLabel(systemImage: "person", text: selectedAgentName ?? "Agent")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-session-agent")
    }

    private var selectedAgentName: String? {
        if let agent = stockadeAgents?.first(where: { $0.id == selectedAgentID }) { return agent.name }
        return claudeAgents?.first(where: { $0.id == selectedAgentID })?.label
    }

    private var sendButton: some View {
        Button {
            Task { await create() }
        } label: {
            Group {
                if isCreating {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: 36, height: 36)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(.ccAccent).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(isCreating ? "Creating" : "Send")
        .accessibilityIdentifier("new-session-send")
        .disabled(!canCreate || isCreating)
    }

    private var customFolderSheet: some View {
        NavigationStack {
            Form {
                TextField("/absolute/path", text: $customFolderDraft)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("new-session-other-path")
            }
            .navigationTitle("Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isCustomFolderPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let path = customFolderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !path.isEmpty else { return }
                        selectedFolderPath = path
                        isCustomFolderPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func chipLabel(systemImage: String, text: String) -> some View {
        Label {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.footnote)
        .foregroundStyle(.ccLabel)
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func selectInitialController() {
        guard let binding = selectedControllerID, !controllerChoices.isEmpty else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.lastControllerKey),
           let savedID = ControllerID(rawValue: saved),
           controllerChoices.contains(where: { $0.id == savedID }) {
            binding.wrappedValue = savedID
        } else if !controllerChoices.contains(where: { $0.id == binding.wrappedValue }) {
            binding.wrappedValue = controllerChoices[0].id
        }
    }

    private func loadOptions() {
        guard !isCreating else { return }
        let controllerID = currentControllerID
        loading = true
        options = nil
        loadError = nil
        createError = nil
        selectedFolderPath = nil
        selectedAgentID = nil
        Task { @MainActor in
            do {
                let loaded = try await store.newSessionOptions()
                guard currentControllerID == controllerID else { return }
                options = loaded
                restoreSelections(from: loaded, controllerID: controllerID)
                loading = false
            } catch {
                guard currentControllerID == controllerID else { return }
                loading = false
                loadError = errorMessage(error)
            }
        }
    }

    private func restoreSelections(from options: NewSessionOptions, controllerID: ControllerID) {
        if options.agents != nil {
            let available = options.agents ?? []
            let saved = UserDefaults.standard.string(forKey: Self.agentKeyPrefix + controllerID.rawValue)
            selectedAgentID = available.first(where: { $0.id == saved })?.id ?? available.first?.id
            return
        }

        let savedFolder = UserDefaults.standard.string(forKey: Self.folderKeyPrefix + controllerID.rawValue)
        selectedFolderPath = options.folders.first(where: { $0.path == savedFolder })?.path ?? options.folders.first?.path
        let available = options.claudeAgents ?? []
        let savedAgent = UserDefaults.standard.string(forKey: Self.agentKeyPrefix + controllerID.rawValue)
        selectedAgentID = available.first(where: { $0.id == savedAgent })?.id
            ?? available.first(where: { $0.id == "default" })?.id
            ?? available.first?.id
    }

    private func focusPrompt() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            promptFocused = true
        }
    }

    private func create() async {
        guard !isCreating, canCreate, let options else { return }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let created: CreatedSession
            if isStockade {
                guard let selectedAgentID else { return }
                created = try await store.createAgentSession(agentId: selectedAgentID, prompt: trimmedPrompt)
            } else {
                guard let cwd = selectedFolderPath else { return }
                let agent = selectedAgentID == "default" ? nil : selectedAgentID
                created = try await store.createSession(
                    cwd: cwd,
                    name: nil,
                    model: nil,
                    defaultModel: options.defaultModel,
                    prompt: trimmedPrompt,
                    agent: agent
                )
            }
            saveSelections(controllerID: currentControllerID)
            let appeared = await store.waitForSession(created.id)
            dismiss()
            onCreated(created.id, appeared)
        } catch {
            createError = errorMessage(error)
        }
    }

    private func saveSelections(controllerID: ControllerID) {
        UserDefaults.standard.set(controllerID.rawValue, forKey: Self.lastControllerKey)
        if let selectedFolderPath {
            UserDefaults.standard.set(selectedFolderPath, forKey: Self.folderKeyPrefix + controllerID.rawValue)
        }
        if let selectedAgentID {
            UserDefaults.standard.set(selectedAgentID, forKey: Self.agentKeyPrefix + controllerID.rawValue)
        }
    }

    private func folderLastComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    private func errorMessage(_ error: Error) -> String {
        if let apiError = error as? APIError {
            if case .http(_, _, let code) = apiError, code == "session_registry_timeout" {
                return "The session did not start in time."
            }
            return apiError.daemonMessage ?? apiError.localizedDescription
        }
        return error.localizedDescription
    }
}
