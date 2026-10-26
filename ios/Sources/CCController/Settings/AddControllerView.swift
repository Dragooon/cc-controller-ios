import CCKit
import SwiftUI

/// Settings > Add controller, pushed inside the Settings navigation stack.
struct AddControllerView: View {
    @State private var flow: AddControllerModel
    let onDone: () -> Void

    init(appModel: AppModel, onDone: @escaping () -> Void) {
        _flow = State(initialValue: appModel.makeAddControllerModel())
        self.onDone = onDone
    }

    var body: some View {
        Form {
            switch flow.step {
            case .details, .done:
                detailsSections
            case .connecting:
                connectingSection
            case .pairing(let code, let expiresAt):
                pairingSections(code: code, expiresAt: expiresAt)
            case .faceID:
                faceIDSection
            }
            if let message = flow.message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.ccAccent)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("add-controller-message")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.ccBackground)
        .navigationTitle("Add controller")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: flow.step) { _, step in
            if step == .done { onDone() }
        }
        .onDisappear {
            flow.cancel()
        }
        .sensoryFeedback(.success, trigger: flow.copiedPairingCommand) { _, newValue in
            newValue
        }
    }

    @ViewBuilder
    private var detailsSections: some View {
        Section("Name") {
            TextField("Mustafar", text: $flow.draft.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .accessibilityIdentifier("add-controller-name")
        }
        Section {
            TextEditor(text: $flow.draft.addresses)
                .font(.footnote.monospaced())
                .frame(minHeight: 72)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("add-controller-addresses")
            if !flow.draft.addresses.isEmpty, flow.draft.problem == .addressesInvalid {
                Text(AddControllerDraft.Problem.addressesInvalid.text)
                    .font(.footnote)
                    .foregroundStyle(.ccAccent)
            }
        } header: {
            Text("Addresses")
        } footer: {
            Text("Pinned-TLS addresses as IP:port, one per line: a relay port or the controller's own listener.")
                .font(.footnote)
                .foregroundStyle(.ccSecondary)
        }
        Section {
            Button {
                flow.connect()
            } label: {
                Text("Connect")
                    .frame(maxWidth: .infinity)
            }
            .disabled(flow.draft.problem != nil)
            .accessibilityIdentifier("add-controller-connect")
        }
    }

    private var connectingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(flow.addressSummary)…")
                    .foregroundStyle(.ccSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("add-controller-connecting")
            Button("Cancel", role: .cancel) { flow.cancel() }
        }
    }

    @ViewBuilder
    private func pairingSections(code: String, expiresAt: Date) -> some View {
        Section {
            Text(spacedCode(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(.ccLabel)
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.75)
                .accessibilityIdentifier("add-controller-pairing-code")
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
        } header: {
            Text("Pairing code")
        }
        Section {
            Text(flow.pairingCommand ?? "")
                .font(.body.monospaced())
                .foregroundStyle(.ccLabel)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add-controller-pairing-command")
            Button {
                flow.copyPairingCommand()
            } label: {
                Label(flow.copiedPairingCommand ? "Copied" : "Copy", systemImage: flow.copiedPairingCommand ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(flow.copiedPairingCommand ? "Pairing command copied" : "Copy pairing command")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                Text(String(format: "Expires in %d:%02d", seconds / 60, seconds % 60))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.ccSecondary)
            }
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for \(flow.draft.trimmedName)…")
                    .font(.subheadline)
                    .foregroundStyle(.ccSecondary)
            }
            .accessibilityElement(children: .combine)
            Button("Cancel", role: .cancel) { flow.cancel() }
        } header: {
            Text("On \(flow.draft.trimmedName), run")
        }
    }

    private var faceIDSection: some View {
        Section {
            Text("Protect with Face ID")
                .font(.headline)
                .foregroundStyle(.ccLabel)
            Text("\(flow.draft.trimmedName) approved this iPhone. Face ID keeps its sign-in on this device.")
                .font(.footnote)
                .foregroundStyle(.ccSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await flow.enrollAndSignIn() }
            } label: {
                if flow.isEnrolling {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for Face ID…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Turn on Face ID")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(flow.isEnrolling)
            .accessibilityIdentifier("add-controller-face-id")
            Button("Cancel", role: .cancel) { flow.cancel() }
        }
    }

    private func spacedCode(_ code: String) -> String {
        guard code.count > 3 else { return code }
        let midpoint = code.index(code.startIndex, offsetBy: code.count - 3)
        return "\(code[..<midpoint]) \(code[midpoint...])"
    }
}
