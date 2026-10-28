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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
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
    @State private var greeting: String?

    private static let lastControllerKey = "newSession.lastControllerID"
    private static let ownerNameKey = "newSession.ownerName"
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

    private var visibleClaudeAgents: [ClaudeAgentOption] {
        guard let agents = claudeAgents,
              let resolvesTo = agents.first(where: { $0.id == "default" })?.resolvesTo else {
            return claudeAgents ?? []
        }
        return agents.filter { $0.id != resolvesTo }
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
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let greeting {
                    VStack(spacing: 12) {
                        SpinnerGlyph(active: true, frozen: true)
                            .font(.system(size: 36))
                        Text(greeting)
                            .font(.system(size: 30, weight: .regular, design: .serif))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 24)
                            .accessibilityIdentifier("new-session-greeting")
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { promptFocused = false }
            .background(.ccBackground)
            .safeAreaBar(edge: .bottom, spacing: 0) {
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
                    composer
                        .offset(y: verticalSizeClass == .compact ? 0 : 12)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ccBackground)
            }
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

    private var composer: some View {
        ComposerCard {
            TextField(promptPlaceholder, text: $prompt, axis: .vertical)
                .font(.body)
                .foregroundStyle(.ccLabel)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.sentences)
                .focused($promptFocused)
                .accessibilityIdentifier("new-session-prompt")

            controls
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-session-composer")
    }

    private var promptPlaceholder: String {
        "Chat with \(selectedAgentName ?? "Claude")"
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
                    } else if !isStockade, visibleClaudeAgents.isEmpty == false {
                        claudeAgentMenu
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            sendButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            ForEach(visibleClaudeAgents) { agent in
                Button {
                    selectedAgentID = agent.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.label)
                        if agent.id == "default" {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let description = agent.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel(agent.id == "default" ? "\(agent.label), Default" : agent.label)
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
        return visibleClaudeAgents.first(where: { $0.id == selectedAgentID })?.label
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
                if let ownerName = loaded.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !ownerName.isEmpty {
                    UserDefaults.standard.set(ownerName, forKey: Self.ownerNameKey)
                    setGreeting(name: ownerName)
                } else {
                    setGreeting(name: UserDefaults.standard.string(forKey: Self.ownerNameKey))
                }
                restoreSelections(from: loaded, controllerID: controllerID)
                loading = false
            } catch {
                guard currentControllerID == controllerID else { return }
                loading = false
                setGreeting(name: UserDefaults.standard.string(forKey: Self.ownerNameKey))
                loadError = errorMessage(error)
            }
        }
    }

    private func setGreeting(name: String?) {
        guard greeting == nil else { return }
        greeting = NewSessionGreeting.text(date: Date(), name: name)
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
        let available = visibleClaudeAgents
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
