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
    var promptBinding: Binding<String>? = nil
    var isEmbedded = false
    let onCreated: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState private var promptFocused: Bool

    @State private var options: NewSessionOptions?
    @State private var loading = true
    @State private var loadError: String?
    @State private var createError: String?
    @State private var selectedFolderPath: String?
    @State private var selectedAgentID: String?
    /// Nil starts the session on the controller's default model.
    @State private var selectedModelID: String?
    /// Nil is the model's own default level.
    @State private var selectedEffortID: String?
    @State private var prompt = ""
    @State private var isCreating = false
    @State private var customFolderDraft = ""
    @State private var isCustomFolderPresented = false
    @State private var greeting: String?

    private static let lastControllerKey = "newSession.lastControllerID"
    private static let ownerNameKey = "newSession.ownerName"
    private static let folderKeyPrefix = "newSession.folder."
    private static let agentKeyPrefix = "newSession.agent."
    private static let modelKeyPrefix = "newSession.model."
    private static let effortKeyPrefix = "newSession.effort."

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

    private var selectedStockadeAgent: NewSessionAgent? {
        stockadeAgents?.first(where: { $0.id == selectedAgentID })
    }

    /// Folder sessions always pick a folder; a Stockade agent only when it has no folder of its own.
    private var showsFolderChoice: Bool {
        guard isStockade else { return true }
        return selectedStockadeAgent?.choosesFolder == true && options?.folders.isEmpty == false
    }

    private var availableModels: [ModelOption] {
        options?.models ?? []
    }

    /// The effort levels the chosen model takes. Empty on a controller without effort levels.
    private var availableEfforts: [EffortOption] {
        guard store.supports(.effort), let options else { return [] }
        return effortOptions(options.efforts ?? [], forModel: selectedModelID ?? defaultModelID(in: options), models: options.models)
            .filter { !isDefaultEffort($0.id) }
    }

    /// The model "Default" launches with the chosen agent.
    private func defaultModelID(in options: NewSessionOptions) -> String {
        newSessionDefaultModelID(options: options, agent: selectedStockadeAgent)
    }

    private var defaultEffortText: String {
        guard let options else { return "Default" }
        let level = newSessionDefaultEffortID(options: options, agent: selectedStockadeAgent, pickedModelID: selectedModelID)
        let name = effortLabel(level, options: options.efforts ?? [])
        return name.map { "Default (\($0))" } ?? "Default"
    }

    private var selectedEffortText: String {
        guard let selectedEffortID else { return defaultEffortText }
        return effortLabel(selectedEffortID, options: options?.efforts ?? []) ?? selectedEffortID
    }

    private var newSessionTitle: some View {
        Text("New session")
            .font(.headline)
            .accessibilityIdentifier("new-session-title")
    }

    private var canCreate: Bool {
        guard let options, !loading, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isStockade { return selectedAgentID?.isEmpty == false }
        return selectedFolderPath != nil
    }

    var body: some View {
        Group {
            if isEmbedded {
                page
            } else {
                NavigationStack {
                    page
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(isCreating)
            }
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let greeting {
                VStack(spacing: 12) {
                    SpinnerGlyph(active: true, frozen: true)
                        .font(.system(size: 36))
                    Text(greeting)
                        .font(.system(size: 30, weight: .regular))
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
            if isEmbedded {
                ToolbarItem(placement: .principal) {
                    newSessionTitle
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
            }
        }
        .tint(.ccAccent)
        .onAppear {
            if let promptBinding {
                prompt = promptBinding.wrappedValue
            }
            selectInitialController()
            loadOptions()
            focusPrompt()
        }
        .onDisappear {
            promptBinding?.wrappedValue = prompt
        }
        .onChange(of: selectedControllerID?.wrappedValue) { _, _ in
            loadOptions()
        }
        .onChange(of: prompt) { _, value in
            promptBinding?.wrappedValue = value
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
                    } else if showsFolderChoice {
                        folderMenu
                    }
                    if loading {
                        loadingChip
                    } else if isStockade, stockadeAgents?.isEmpty == false {
                        stockadeAgentMenu
                    } else if !isStockade, visibleClaudeAgents.isEmpty == false {
                        claudeAgentMenu
                    }
                    if !loading, !availableModels.isEmpty {
                        modelMenu
                    }
                    if !loading, !availableEfforts.isEmpty {
                        effortMenu
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

    private var modelMenu: some View {
        Menu {
            Button {
                selectedModelID = nil
            } label: {
                Text("Default (\(defaultModelLabel))")
            }
            .accessibilityIdentifier("new-session-model-default")
            ForEach(availableModels) { model in
                Button {
                    selectedModelID = model.id
                } label: {
                    Text(model.label)
                }
                .accessibilityIdentifier("new-session-model-\(model.id)")
            }
        } label: {
            chipLabel(systemImage: "cpu", text: selectedModelLabel)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-session-model")
    }

    private var effortMenu: some View {
        Menu {
            Button {
                selectedEffortID = nil
            } label: {
                Text(defaultEffortText)
            }
            .accessibilityIdentifier("new-session-effort-default")
            ForEach(availableEfforts) { effort in
                Button {
                    selectedEffortID = effort.id
                } label: {
                    Text(effort.label)
                }
                .accessibilityIdentifier("new-session-effort-\(effort.id)")
            }
        } label: {
            chipLabel(systemImage: "gauge.with.needle", text: selectedEffortText)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-session-effort")
        // A level the newly chosen model doesn't take goes back to that model's default.
        .onChange(of: selectedModelID) { _, _ in
            dropEffortTheModelDoesNotTake()
        }
        // Another agent can mean another default model, with other levels.
        .onChange(of: selectedAgentID) { _, _ in
            dropEffortTheModelDoesNotTake()
        }
    }

    private func dropEffortTheModelDoesNotTake() {
        if let selectedEffortID, !availableEfforts.contains(where: { $0.id == selectedEffortID }) {
            self.selectedEffortID = nil
        }
    }

    private var defaultModelLabel: String {
        guard let options else { return "default" }
        return newSessionDefaultModelLabel(options: options, agent: selectedStockadeAgent)
    }

    private var selectedModelLabel: String {
        guard let selectedModelID else { return defaultModelLabel }
        return availableModels.first(where: { $0.id == selectedModelID })?.label ?? selectedModelID
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
        selectedModelID = nil
        selectedEffortID = nil
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
        let savedModel = UserDefaults.standard.string(forKey: Self.modelKeyPrefix + controllerID.rawValue)
        selectedModelID = options.models.first(where: { $0.id == savedModel })?.id
        let savedFolder = UserDefaults.standard.string(forKey: Self.folderKeyPrefix + controllerID.rawValue)
        selectedFolderPath = options.folders.first(where: { $0.path == savedFolder })?.path ?? options.folders.first?.path

        // The agent comes before the effort level: it decides which model "Default" is, and so which levels fit.
        let savedAgent = UserDefaults.standard.string(forKey: Self.agentKeyPrefix + controllerID.rawValue)
        var stockadeAgent: NewSessionAgent?
        if let stockadeAgents = options.agents {
            stockadeAgent = stockadeAgents.first(where: { $0.id == savedAgent }) ?? stockadeAgents.first
            selectedAgentID = stockadeAgent?.id
        } else {
            let available = visibleClaudeAgents
            selectedAgentID = available.first(where: { $0.id == savedAgent })?.id
                ?? available.first(where: { $0.id == "default" })?.id
                ?? available.first?.id
        }

        let savedEffort = UserDefaults.standard.string(forKey: Self.effortKeyPrefix + controllerID.rawValue)
        let modelForEffort = selectedModelID ?? newSessionDefaultModelID(options: options, agent: stockadeAgent)
        selectedEffortID = effortOptions(options.efforts ?? [], forModel: modelForEffort, models: options.models)
            .first(where: { $0.id == savedEffort && !isDefaultEffort($0.id) })?.id
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
                created = try await store.createAgentSession(
                    agentId: selectedAgentID,
                    prompt: trimmedPrompt,
                    model: selectedModelID,
                    cwd: showsFolderChoice ? selectedFolderPath : nil,
                    effort: createEffort
                )
            } else {
                guard let cwd = selectedFolderPath else { return }
                let agent = selectedAgentID == "default" ? nil : selectedAgentID
                created = try await store.createSession(
                    cwd: cwd,
                    name: nil,
                    model: selectedModelID,
                    defaultModel: options.defaultModel,
                    prompt: trimmedPrompt,
                    agent: agent,
                    effort: createEffort
                )
            }
            saveSelections(controllerID: currentControllerID)
            let appeared = await store.waitForSession(created.id)
            if !isEmbedded {
                dismiss()
            }
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
        // A pick of the default is remembered as no pick, so a later change of default still applies.
        UserDefaults.standard.set(selectedModelID, forKey: Self.modelKeyPrefix + controllerID.rawValue)
        UserDefaults.standard.set(selectedEffortID, forKey: Self.effortKeyPrefix + controllerID.rawValue)
    }

    /// The level to start with, sent only when it's one the chosen model takes on a controller with effort levels.
    private var createEffort: String? {
        guard let selectedEffortID, availableEfforts.contains(where: { $0.id == selectedEffortID }) else { return nil }
        return selectedEffortID
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
