import CCKit
import SwiftUI

struct NewSessionView: View {
    let store: AppStore
    let onCreated: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var options: NewSessionOptions?
    @State private var loading = true
    @State private var loadError: String?
    @State private var createError: String?
    @State private var selectedFolderPath: String?
    @State private var isOtherFolder = false
    @State private var otherPath = ""
    @State private var name = ""
    @State private var selectedModel = ""
    @State private var firstMessage = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                if let createError {
                    Section {
                        Text(createError)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("new-session-error")
                    }
                }

                if loading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading options…")
                                .foregroundStyle(.ccSecondary)
                        }
                        .accessibilityIdentifier("new-session-loading")
                    }
                } else if let loadError {
                    Section {
                        Text(loadError)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry", action: loadOptions)
                            .accessibilityIdentifier("new-session-retry")
                    }
                } else if let options {
                    folderRow(options)
                    nameSection
                    modelSection(options)
                    messageSection
                    Section {
                        EmptyView()
                    } footer: {
                        Text("Runs on your Mac as a background session. Open it there with `claude attach <name>`.")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            .scrollContentBackground(.hidden)
            .background(.ccBackground)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                        }
                    }
                    .accessibilityLabel(isCreating ? "Creating" : "Create")
                    .accessibilityIdentifier("new-session-create")
                    .disabled(isCreating || !canCreate)
                }
            }
            .tint(.ccAccent)
        }
        .task { loadOptions() }
        .interactiveDismissDisabled(isCreating)
    }

    @ViewBuilder
    private func folderRow(_ options: NewSessionOptions) -> some View {
        Section("Folder") {
            NavigationLink {
                FolderPickerView(
                    options: options,
                    selectedFolderPath: $selectedFolderPath,
                    isOtherFolder: $isOtherFolder,
                    otherPath: $otherPath
                )
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folderDisplayName(options))
                            .font(.body)
                            .foregroundStyle(.ccLabel)
                        Text(folderDisplayPath(options))
                            .font(.footnote)
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
            }
            .accessibilityIdentifier("new-session-folder-row")
        }
    }

    private var nameSection: some View {
        Section("Name") {
            TextField(namePlaceholder, text: $name)
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier("new-session-name")
        }
    }

    private func modelSection(_ options: NewSessionOptions) -> some View {
        Section {
            Picker("Model", selection: $selectedModel) {
                ForEach(options.models) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("new-session-model")
        }
    }

    private var messageSection: some View {
        Section("First message") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $firstMessage)
                    .frame(minHeight: 90)
                    .accessibilityIdentifier("new-session-first-message")
                if firstMessage.isEmpty {
                    Text("Optional. Without one, the session waits for your first message.")
                        .foregroundStyle(.ccTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var canCreate: Bool {
        if !isOtherFolder { return selectedFolderPath != nil }
        return !otherPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var namePlaceholder: String {
        guard !isOtherFolder, let path = selectedFolderPath,
              let folder = options?.folders.first(where: { $0.path == path }) else { return "Session name" }
        return folder.name
    }

    private func folderDisplayName(_ options: NewSessionOptions) -> String {
        if isOtherFolder { return "Other folder" }
        return options.folders.first(where: { $0.path == selectedFolderPath })?.name ?? "Choose a folder"
    }

    private func folderDisplayPath(_ options: NewSessionOptions) -> String {
        if isOtherFolder { return displayPath(otherPath) }
        guard let path = selectedFolderPath else { return "" }
        return displayPath(path)
    }

    private func displayPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" else { return path }
        return "~" + (components.dropFirst(2).isEmpty ? "" : "/" + components.dropFirst(2).joined(separator: "/"))
    }

    private func loadOptions() {
        guard !isCreating else { return }
        loading = true
        loadError = nil
        createError = nil
        Task { @MainActor in
            do {
                let loaded = try await store.newSessionOptions()
                options = loaded
                selectedFolderPath = loaded.folders.first?.path
                isOtherFolder = false
                selectedModel = loaded.models.first(where: { $0.id == loaded.defaultModel })?.id ?? loaded.models.first?.id ?? ""
                loading = false
            } catch {
                loading = false
                loadError = errorMessage(error)
            }
        }
    }

    private func create() async {
        guard !isCreating, canCreate, let options else { return }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        let cwd = selectedFolderPath ?? otherPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created = try await store.createSession(
                cwd: cwd,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name,
                model: selectedModel.isEmpty ? nil : selectedModel,
                defaultModel: options.defaultModel,
                prompt: firstMessage.isEmpty ? nil : firstMessage
            )
            let appeared = await store.waitForSession(created.id)
            dismiss()
            onCreated(created.id, appeared)
        } catch {
            createError = errorMessage(error)
        }
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

private struct FolderPickerView: View {
    let options: NewSessionOptions
    @Binding var selectedFolderPath: String?
    @Binding var isOtherFolder: Bool
    @Binding var otherPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredFolders: [NewSessionFolder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options.folders }
        return options.folders.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section("Recent") {
                ForEach(filteredFolders) { folder in
                    Button {
                        selectedFolderPath = folder.path
                        isOtherFolder = false
                        otherPath = ""
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name)
                                    .foregroundStyle(.ccLabel)
                                Text(displayPath(folder.path))
                                    .font(.footnote)
                                    .foregroundStyle(.ccSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            if !isOtherFolder && selectedFolderPath == folder.path {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.ccAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("new-session-folder-\(folder.name)")
                }
            }
            Section("Other folder") {
                TextField("/absolute/path", text: $otherPath)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("new-session-other-path")
                    .onSubmit { selectOtherIfValid() }
                if !otherPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Use this folder") { selectOtherIfValid() }
                        .accessibilityIdentifier("new-session-use-other-folder")
                }
            }
        }
        .navigationTitle("Folder")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search folders")
        .tint(.ccAccent)
    }

    private func selectOtherIfValid() {
        guard !otherPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectedFolderPath = nil
        isOtherFolder = true
        dismiss()
    }

    private func displayPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" else { return path }
        return "~" + (components.dropFirst(2).isEmpty ? "" : "/" + components.dropFirst(2).joined(separator: "/"))
    }
}
