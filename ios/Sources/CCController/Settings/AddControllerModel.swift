import CCKit
import Foundation
import Observation
import UIKit

/// Runs Add controller against a new controller's own connection: reach its addresses, show a pairing code that
/// `cc-gateway pair <code> <check>` confirms on that host, then protect it with Face ID and sign in.
/// Only a controller that finishes every step is kept; anything half-paired is deleted.
@MainActor @Observable
final class AddControllerModel {
    enum Step: Equatable {
        case details
        case connecting
        case pairing(code: String, expiresAt: Date)
        case faceID
        case done
    }

    var draft = AddControllerDraft()
    private(set) var step: Step = .details
    private(set) var message: String?
    private(set) var isEnrolling = false
    private(set) var copiedPairingCommand = false

    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let existingIDs: @MainActor () -> [ControllerID]
    @ObservationIgnored private let makeConnection: @MainActor (ControllerConfig) -> ControllerConnection
    @ObservationIgnored private let adopt: @MainActor (ControllerConnection) -> Void
    @ObservationIgnored private var connection: ControllerConnection?
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var discardTask: Task<Void, Never>?
    @ObservationIgnored private var nativeSecretEnrolled = false

    init(
        deviceName: String,
        existingIDs: @escaping @MainActor () -> [ControllerID],
        makeConnection: @escaping @MainActor (ControllerConfig) -> ControllerConnection,
        adopt: @escaping @MainActor (ControllerConnection) -> Void
    ) {
        self.deviceName = deviceName
        self.existingIDs = existingIDs
        self.makeConnection = makeConnection
        self.adopt = adopt
    }

    var pairingCode: String? {
        guard case .pairing(let code, _) = step else { return nil }
        return code
    }

    var pairingExpiresAt: Date? {
        guard case .pairing(_, let expiresAt) = step else { return nil }
        return expiresAt
    }

    /// The command to run on the new controller's host. Relay pairings need the identity check.
    var pairingCommand: String? {
        guard let pairingCode else { return nil }
        guard let check = connection?.router.observedPin.flatMap({ try? RelayPin($0).check }) else {
            return "cc-gateway pair \(pairingCode)"
        }
        return "cc-gateway pair \(pairingCode) \(check)"
    }

    var addressSummary: String {
        (ControllerConfig.addressEndpoints(from: draft.addresses) ?? []).map(controllerAddressText).joined(separator: ", ")
    }

    func connect() {
        guard let config = draft.config(existing: existingIDs()) else {
            message = draft.problem?.text
            return
        }
        flowTask?.cancel()
        discardConnection()
        message = nil
        nativeSecretEnrolled = false
        step = .connecting
        let previousDiscard = discardTask
        flowTask = Task { @MainActor [weak self] in
            // A retry reuses the same controller id, so the previous attempt's Keychain items must be gone first.
            await previousDiscard?.value
            guard let self, !Task.isCancelled else { return }
            let connection = makeConnection(config)
            self.connection = connection
            await run(connection, config: config)
        }
    }

    func copyPairingCommand() {
        guard let pairingCommand else { return }
        UIPasteboard.general.string = pairingCommand
        copiedPairingCommand = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copiedPairingCommand = false
        }
    }

    func enrollAndSignIn() async {
        guard step == .faceID, !isEnrolling, let connection else { return }
        isEnrolling = true
        defer { isEnrolling = false }
        message = nil
        if !nativeSecretEnrolled {
            switch await connection.auth.enroll() {
            case .success:
                nativeSecretEnrolled = true
            case .failure(let error):
                if error == .enrollmentWindowClosed {
                    fail("The Face ID setup window expired. Start pairing again.")
                } else {
                    message = faceIDFailureMessage(for: error)
                }
                return
            }
        }
        switch await connection.auth.unlock() {
        case .success:
            self.connection = nil
            adopt(connection)
            step = .done
        case .failure(let error):
            message = faceIDFailureMessage(for: error)
        }
    }

    /// Back or Cancel: stops the flow and deletes anything half-paired.
    func cancel() {
        flowTask?.cancel()
        flowTask = nil
        discardConnection()
        if step != .done { step = .details }
    }

    private func run(_ connection: ControllerConnection, config: ControllerConfig) async {
        var failures = 0
        while true {
            do {
                _ = try await connection.auth.probeDaemon(timeout: 5)
                break
            } catch {
                guard !Task.isCancelled else { return }
                if connection.router.hasPinMismatch {
                    fail("\(config.displayName) presented a different identity on one of its addresses.")
                    return
                }
                failures += 1
                if failures >= 3 {
                    fail("Can't reach \(addressSummary). Check the addresses and that the controller is listening.")
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        guard !Task.isCancelled else { return }
        switch await connection.auth.startPairing(deviceName: deviceName) {
        case .success:
            guard let details = connection.auth.pairingDetails else {
                fail("\(config.displayName) returned an invalid pairing code.")
                return
            }
            step = .pairing(code: details.code, expiresAt: details.expiresAt)
            await pollPairing(connection, expiresAt: details.expiresAt)
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    private func pollPairing(_ connection: ControllerConnection, expiresAt: Date) async {
        while !Task.isCancelled {
            if Date() >= expiresAt {
                fail("The pairing code expired. Connect again for a new one.")
                return
            }
            switch await connection.auth.pollPairing() {
            case .success:
                if case .enrolling = connection.auth.state {
                    step = .faceID
                    return
                }
            case .failure(let error):
                guard !Task.isCancelled else { return }
                if connection.router.hasPinMismatch {
                    fail("The controller's identity changed while pairing. Check the addresses.")
                } else if error == .pairingExpired {
                    fail("The pairing code expired. Connect again for a new one.")
                } else {
                    fail(error.localizedDescription)
                }
                return
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func fail(_ text: String) {
        discardConnection()
        message = text
        step = .details
    }

    private func discardConnection() {
        guard let connection else { return }
        self.connection = nil
        connection.store.suspend()
        let previous = discardTask
        discardTask = Task { @MainActor in
            await previous?.value
            // unpair clears the device token, native secret, relay pin and auth cache.
            _ = await connection.auth.unpair()
            try? FileManager.default.removeItem(at: connection.cacheDirectory)
        }
    }
}
