import CCKit
import SwiftUI

enum SettingsLockInterval: String, CaseIterable, Identifiable {
    case immediately = "Immediately"
    case fiveMinutes = "After 5 minutes"
    case oneHour = "After 1 hour"

    var id: String { rawValue }

    init(_ interval: LockInterval) {
        switch interval {
        case .immediately: self = .immediately
        case .fiveMinutes: self = .fiveMinutes
        case .oneHour: self = .oneHour
        case .custom: self = .fiveMinutes
        }
    }

    var lockInterval: LockInterval {
        switch self {
        case .immediately: .immediately
        case .fiveMinutes: .fiveMinutes
        case .oneHour: .oneHour
        }
    }
}

struct SettingsView: View {
    let address: String
    let relayMode: Bool
    let relayAddresses: String
    let relayPin: String?
    let connectedVia: String?
    let latency: SettingsLatency
    let connectionTest: SettingsConnectionTest?
    let thisDevice: SettingsLoad<SettingsThisDevice>
    let pairedDevices: SettingsLoad<[SettingsPairedDeviceRow]>
    let appVersion: String
    let daemon: DaemonInfo?
    let apiVersion: Int?
    let isUnpairing: Bool
    let onDone: () -> Void
    let onTestConnection: () -> Void
    let onLockNow: () -> Void
    let onUnpair: () -> Void
    let onLockInterval: (SettingsLockInterval) -> Void
    let onRetryDevices: () -> Void
    let onRelayAddressesChanged: (String) -> Void
    let onResetRelayAddresses: () -> Void
    let lockAfter: SettingsLockInterval

    @State private var selectedLockInterval: SettingsLockInterval
    @State private var relayAddressDraft: String
    @State private var showingUnpairConfirmation = false

    init(
        address: String = "127.0.0.1:47832",
        relayMode: Bool = false,
        relayAddresses: String = "",
        relayPin: String? = nil,
        connectedVia: String? = nil,
        latency: SettingsLatency = .checking,
        connectionTest: SettingsConnectionTest? = nil,
        thisDevice: SettingsLoad<SettingsThisDevice> = .loading,
        pairedDevices: SettingsLoad<[SettingsPairedDeviceRow]> = .loading,
        appVersion: String = "Unknown",
        daemon: DaemonInfo? = nil,
        apiVersion: Int? = nil,
        isUnpairing: Bool = false,
        lockAfter: SettingsLockInterval = .fiveMinutes,
        onDone: @escaping () -> Void = {},
        onTestConnection: @escaping () -> Void = {},
        onLockNow: @escaping () -> Void = {},
        onUnpair: @escaping () -> Void = {},
        onLockInterval: @escaping (SettingsLockInterval) -> Void = { _ in },
        onRetryDevices: @escaping () -> Void = {},
        onRelayAddressesChanged: @escaping (String) -> Void = { _ in },
        onResetRelayAddresses: @escaping () -> Void = {}
    ) {
        self.address = address
        self.relayMode = relayMode
        self.relayAddresses = relayAddresses
        self.relayPin = relayPin
        self.connectedVia = connectedVia
        self.latency = latency
        self.connectionTest = connectionTest
        self.thisDevice = thisDevice
        self.pairedDevices = pairedDevices
        self.appVersion = appVersion
        self.daemon = daemon
        self.apiVersion = apiVersion
        self.isUnpairing = isUnpairing
        self.lockAfter = lockAfter
        self.onDone = onDone
        self.onTestConnection = onTestConnection
        self.onLockNow = onLockNow
        self.onUnpair = onUnpair
        self.onLockInterval = onLockInterval
        self.onRetryDevices = onRetryDevices
        self.onRelayAddressesChanged = onRelayAddressesChanged
        self.onResetRelayAddresses = onResetRelayAddresses
        _selectedLockInterval = State(initialValue: lockAfter)
        _relayAddressDraft = State(initialValue: relayAddresses)
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
        Section {
            if relayMode {
                if let connectedVia {
                    LabeledContent("Connected via") {
                        Text("\(connectedVia) (\(address))")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.ccLabel)
                            .multilineTextAlignment(.trailing)
                    }
                    .settingsValue("Connected via", "\(connectedVia) (\(address))", id: "settings-address")
                }
                if let relayPin {
                    LabeledContent("Mac identity", value: relayPin)
                        .font(.footnote.monospaced())
                        .settingsValue("Mac identity", relayPin, id: "settings-relay-pin")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Relay addresses")
                    TextEditor(text: $relayAddressDraft)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 72)
                        .accessibilityIdentifier("settings-relay-addresses")
                        .onChange(of: relayAddressDraft) { _, value in
                            onRelayAddressesChanged(value)
                        }
                    if parseRelayAddresses(relayAddressDraft) == nil {
                        Text("Use IP addresses only.")
                            .font(.footnote)
                            .foregroundStyle(.ccAccent)
                    }
                    Button("Reset to default", action: onResetRelayAddresses)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("settings-relay-reset")
                }
            } else {
                LabeledContent("Address") {
                    Text(address)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.ccLabel)
                }
                .settingsValue("Address", address, id: "settings-address")
            }

            HStack {
                Text("Latency")
                Spacer()
                Circle()
                    .fill(latencyColor)
                    .frame(width: 8, height: 8)
                Text(settingsLatencyText(latency))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(latency == .unreachable ? .ccRed : .ccLabel)
            }
            .settingsValue("Latency", settingsLatencyText(latency), id: "settings-latency")

            Button(action: onTestConnection) {
                testConnectionLabel
                    .frame(maxWidth: .infinity)
            }
            .disabled(connectionTest == .testing)
            .accessibilityIdentifier("settings-test-connection")

            if let connectionTest, connectionTest != .testing {
                testResultRow(connectionTest)
            }
        } header: {
            Text("Connection")
        } footer: {
            if latency == .unreachable {
                Text(settingsUnreachableGuidance(address: address))
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .accessibilityIdentifier("settings-unreachable-help")
            }
        }
    }

    private var latencyColor: Color {
        switch latency {
        case .checking: .ccTertiary
        case .reachable: .ccGreen
        case .unreachable: .ccRed
        }
    }

    @ViewBuilder
    private var testConnectionLabel: some View {
        if connectionTest == .testing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Testing…")
            }
        } else {
            Text("Test connection")
        }
    }

    private func testResultRow(_ test: SettingsConnectionTest) -> some View {
        let isReachable = if case .reachable = test { true } else { false }
        let testedAt: Date? = switch test {
        case .testing: nil
        case .reachable(_, let at), .unreachable(let at): at
        }
        let time = testedAt?.formatted(date: .omitted, time: .standard) ?? ""
        return HStack(spacing: 8) {
            Image(systemName: isReachable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(isReachable ? .ccGreen : .ccRed)
            Text(connectionTestTitle(test))
                .foregroundStyle(.ccLabel)
            Spacer()
            Text(time)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.ccSecondary)
        }
        .settingsValue("Connection test", "\(connectionTestTitle(test)), tested at \(time)", id: "settings-test-result")
    }

    private var securitySection: some View {
        Section("Security") {
            Picker("Lock after", selection: $selectedLockInterval) {
                ForEach(SettingsLockInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .accessibilityIdentifier("settings-lock-interval")
            .accessibilityValue(selectedLockInterval.rawValue)
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
        let text = SettingsThisDeviceText(thisDevice, now: .now)
        return Section("This device") {
            LabeledContent("Name", value: text.name)
                .settingsValue("Name", text.name, id: "settings-device-name")
            LabeledContent("Paired", value: text.paired)
                .settingsValue("Paired", text.paired, id: "settings-device-paired")
            LabeledContent("Session expires", value: text.expiry)
                .settingsValue("Session expires", text.expiry, id: "settings-device-expiry")

            Button(role: .destructive) {
                showingUnpairConfirmation = true
            } label: {
                if isUnpairing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Unpairing…")
                    }
                } else {
                    Text("Unpair this iPhone")
                }
            }
            .disabled(isUnpairing)
            .accessibilityIdentifier("settings-unpair")
        }
    }

    private var pairedDevicesSection: some View {
        Section {
            pairedDevicesContent
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

    @ViewBuilder
    private var pairedDevicesContent: some View {
        switch pairedDevices {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading devices…")
                    .foregroundStyle(.ccSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-devices-loading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't load paired devices")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccLabel)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-devices-error")
            Button("Retry", action: onRetryDevices)
                .accessibilityIdentifier("settings-devices-retry")
        case .loaded(let devices) where devices.isEmpty:
            Text("No devices are paired with this Mac.")
                .foregroundStyle(.ccSecondary)
                .accessibilityIdentifier("settings-devices-empty")
        case .loaded(let devices):
            ForEach(devices) { device in
                pairedDeviceRow(device)
            }
        }
    }

    private func pairedDeviceRow(_ device: SettingsPairedDeviceRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccLabel)
                Text(lastSeenText(device.lastSeenAt, now: .now))
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
            }
            Spacer()
            if device.isThisDevice {
                Text("This iPhone")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.ccAccent)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(device.isThisDevice ? "settings-paired-this-device" : "settings-paired-device")
    }

    private var aboutSection: some View {
        let daemonVersion = daemonVersionText(daemon)
        let api = apiVersionText(apiVersion)
        return Section("About") {
            LabeledContent("App", value: appVersion)
                .settingsValue("App", appVersion, id: "settings-app-version")
            LabeledContent("cc-controller", value: daemonVersion)
                .settingsValue("cc-controller", daemonVersion, id: "settings-daemon-version")
            LabeledContent("API version", value: api)
                .settingsValue("API version", api, id: "settings-api-version")
        }
    }
}

private extension View {
    /// Collapses a row into one accessibility element so VoiceOver and UI tests read its exact value.
    func settingsValue(_ label: String, _ value: String, id: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(id)
    }
}
