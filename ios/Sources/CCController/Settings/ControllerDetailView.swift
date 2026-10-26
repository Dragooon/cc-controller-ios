import CCKit
import SwiftUI

/// Settings > Controllers > one controller: addresses (editable for relay controllers), identity pin,
/// paired devices, Test connection, and Remove for every controller but the primary.
struct ControllerDetailView: View {
    let model: AppModel
    let controllerID: ControllerID
    let onRemoved: () -> Void

    @State private var addressDraft = ""
    @State private var relayPin: String?
    @State private var showingRemoveConfirmation = false
    @State private var isRemoving = false

    private var row: SettingsControllerRow? { model.controllerRows.first { $0.id == controllerID } }
    private var config: ControllerConfig? { model.config(for: controllerID) }
    private var settings: SettingsStore? { model.settingsStore(for: controllerID) }
    private var isRelay: Bool { config?.directBaseURL == nil }
    private var savedAddresses: String { model.relayAddresses(for: controllerID) }

    var body: some View {
        Form {
            if let row {
                statusSection(row)
                addressSection
                if let relayPin {
                    Section("Identity") {
                        LabeledContent("Identity pin") {
                            Text(relayPin)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.ccLabel)
                                .textSelection(.enabled)
                        }
                        .controllerValue("Identity pin", relayPin, id: "controller-detail-pin")
                    }
                }
                if let settings {
                    connectionTestSection(settings)
                    devicesSection(settings)
                }
                if !row.isPrimary {
                    removeSection(row)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.ccBackground)
        .navigationTitle(row?.name ?? "Controller")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: controllerID) {
            addressDraft = savedAddresses
            relayPin = await model.relayPinGrouped(for: controllerID)
            await settings?.loadPairedDevices()
        }
        .confirmationDialog(
            "Remove \(row?.name ?? "this controller")?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove \(row?.name ?? "controller")", role: .destructive) {
                isRemoving = true
                Task {
                    await model.removeController(controllerID)
                    isRemoving = false
                    onRemoved()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out of the controller and deletes its credentials, caches and settings from this iPhone.")
        }
    }

    private func statusSection(_ row: SettingsControllerRow) -> some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controllerStatusColor(row.status))
                        .frame(width: 8, height: 8)
                    Text(row.status.text)
                        .foregroundStyle(.ccLabel)
                }
            }
            .controllerValue("Status", row.status.text, id: "controller-detail-status")
            LabeledContent("Kind", value: row.kind)
                .controllerValue("Kind", row.kind, id: "controller-detail-kind")
            LabeledContent("In use") {
                Text(row.address)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.ccLabel)
            }
            .controllerValue("In use", row.address, id: "controller-detail-address")
        }
    }

    @ViewBuilder
    private var addressSection: some View {
        if isRelay {
            Section {
                TextEditor(text: $addressDraft)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 72)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("controller-detail-addresses")
                if parseRelayAddresses(addressDraft) == nil {
                    Text("Use IP addresses only.")
                        .font(.footnote)
                        .foregroundStyle(.ccAccent)
                }
                Button("Save") {
                    model.setRelayAddresses(addressDraft, for: controllerID)
                }
                .font(.footnote.weight(.semibold))
                .disabled(parseRelayAddresses(addressDraft) == nil || addressDraft == savedAddresses)
                .accessibilityIdentifier("controller-detail-save")
            } header: {
                Text("Addresses")
            }
        } else if let url = config?.directBaseURL {
            Section("Address") {
                LabeledContent("Address") {
                    Text(controllerAddressText(url))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.ccLabel)
                }
            }
        }
    }

    private func connectionTestSection(_ settings: SettingsStore) -> some View {
        Section {
            Button {
                Task { await settings.testConnection() }
            } label: {
                if settings.connectionTest == .testing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Testing…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Test connection")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(settings.connectionTest == .testing)
            .accessibilityIdentifier("controller-detail-test")
            if let test = settings.connectionTest, test != .testing {
                let title = connectionTestTitle(test)
                Text(title)
                    .foregroundStyle(.ccLabel)
                    .controllerValue("Connection test", title, id: "controller-detail-test-result")
            }
        }
    }

    private func devicesSection(_ settings: SettingsStore) -> some View {
        Section("Paired devices") {
            switch settings.pairedDevices {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading devices…")
                        .foregroundStyle(.ccSecondary)
                }
            case .failed(let message):
                Text("Couldn't load paired devices: \(message)")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                Button("Retry") { Task { await settings.loadPairedDevices() } }
            case .loaded(let devices) where devices.isEmpty:
                Text("No devices are paired with this controller.")
                    .foregroundStyle(.ccSecondary)
            case .loaded(let devices):
                ForEach(devices) { device in
                    HStack {
                        Text(device.name)
                            .foregroundStyle(.ccLabel)
                        Spacer()
                        if device.isThisDevice {
                            Text("This iPhone")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.ccAccent)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("controller-detail-device")
                }
            }
        }
    }

    private func removeSection(_ row: SettingsControllerRow) -> some View {
        Section {
            Button(role: .destructive) {
                showingRemoveConfirmation = true
            } label: {
                if isRemoving {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Removing…")
                    }
                } else {
                    Text("Remove \(row.name)")
                }
            }
            .disabled(isRemoving)
            .accessibilityIdentifier("controller-detail-remove")
        }
    }
}

func controllerStatusColor(_ status: SettingsControllerStatus) -> Color {
    switch status {
    case .live: .ccGreen
    case .connecting: .ccAmber
    case .offline: .ccRed
    case .signInNeeded: .ccAccent
    }
}

private extension View {
    func controllerValue(_ label: String, _ value: String, id: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(id)
    }
}
