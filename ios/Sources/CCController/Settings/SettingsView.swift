import SwiftUI

struct SettingsPairedDevice: Identifiable {
    let id: String
    let name: String
    let lastSeen: String
}

enum SettingsLockInterval: String, CaseIterable, Identifiable {
    case immediately = "Immediately"
    case fiveMinutes = "After 5 minutes"
    case oneHour = "After 1 hour"

    var id: String { rawValue }
}

struct SettingsView: View {
    let onDone: () -> Void
    let onTestConnection: () -> Void
    let onLockNow: () -> Void
    let onUnpair: () -> Void
    let onLockInterval: (SettingsLockInterval) -> Void
    let pairedDevices: [SettingsPairedDevice]
    let lockAfter: SettingsLockInterval

    @State private var selectedLockInterval: SettingsLockInterval
    @State private var showingUnpairConfirmation = false

    init(
        lockAfter: SettingsLockInterval = .fiveMinutes,
        pairedDevices: [SettingsPairedDevice] = [],
        onDone: @escaping () -> Void = {},
        onTestConnection: @escaping () -> Void = {},
        onLockNow: @escaping () -> Void = {},
        onUnpair: @escaping () -> Void = {},
        onLockInterval: @escaping (SettingsLockInterval) -> Void = { _ in }
    ) {
        self.lockAfter = lockAfter
        self.pairedDevices = pairedDevices
        self.onDone = onDone
        self.onTestConnection = onTestConnection
        self.onLockNow = onLockNow
        self.onUnpair = onUnpair
        self.onLockInterval = onLockInterval
        _selectedLockInterval = State(initialValue: lockAfter)
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                securitySection
                deviceSection
                pairedDevicesSection
                aboutSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(.ccBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
            .tint(.ccAccent)
            .accessibilityIdentifier("settings-scroll")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "Unpair this iPhone?",
            isPresented: $showingUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpair this iPhone", role: .destructive, action: onUnpair)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the device credentials and signs out of cc-controller.")
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            Picker("Mode", selection: .constant("Termius forward")) {
                Text("Termius forward").tag("Termius forward")
            }
            Text("Built-in tunnel")
                .foregroundStyle(.ccSecondary)
                .disabled(true)
            Text("Coming in a later version")
                .font(.footnote)
                .foregroundStyle(.ccSecondary)

            LabeledContent("Address") {
                Text("127.0.0.1:47832")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.ccLabel)
            }

            HStack {
                Text("Latency")
                Spacer()
                Circle()
                    .fill(.ccGreen)
                    .frame(width: 8, height: 8)
                Text("18 ms")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.ccLabel)
            }

            Button(action: onTestConnection) {
                Text("Test connection")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var securitySection: some View {
        Section("Security") {
            Picker("Lock after", selection: $selectedLockInterval) {
                ForEach(SettingsLockInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .onChange(of: selectedLockInterval) { _, interval in
                onLockInterval(interval)
            }

            Button(action: onLockNow) {
                Text("Lock now")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var deviceSection: some View {
        Section("This device") {
            LabeledContent("Name", value: "Sam's iPhone")
            LabeledContent("Paired", value: "30 Sep 2026")
            LabeledContent("Session expires", value: "in 11 h")

            Button("Unpair this iPhone", role: .destructive) {
                showingUnpairConfirmation = true
            }
        }
    }

    private var pairedDevicesSection: some View {
        Section {
            ForEach(pairedDevices) { device in
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                    Text("Last seen \(device.lastSeen)")
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Paired devices")
        } footer: {
            (
                Text("Revoke a device on the Mac with ")
                + Text("cc-gateway revoke <name>")
                    .font(.footnote.monospaced())
                + Text(".")
            )
            .font(.footnote)
            .foregroundStyle(.ccSecondary)
            .textSelection(.enabled)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "1.0 (1)")
            LabeledContent("cc-controller", value: "0.1.0 (b961f05)")
            LabeledContent("API version", value: "2")
        }
    }
}
