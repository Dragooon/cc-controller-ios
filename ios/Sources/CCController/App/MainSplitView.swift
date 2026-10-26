import CCKit
import SwiftUI
import UIKit

struct MainSplitView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var allowFeedbackCount = 0
    @State private var denyFeedbackCount = 0
    @State private var isNewSessionPresented = false
    @State private var wakingSessionIDs: Set<String> = []
    @State private var wakeError: String?
    @State private var sessionNotice: String?

    init(model: AppModel) {
        self.model = model
        let hasSelectedSession = model.selectedSession != nil
        _columnVisibility = State(initialValue: hasSelectedSession ? .detailOnly : .all)
        _preferredCompactColumn = State(initialValue: hasSelectedSession ? .detail : .sidebar)
    }

    var body: some View {
        ZStack(alignment: .top) {
            splitView()
#if DEBUG
            Text(horizontalSizeClass == .regular ? "regular" : "compact")
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("horizontal-size-class")
                .accessibilityValue(columnVisibility == .detailOnly ? "detailOnly" : "not-detailOnly")
            Text(" ")
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("controller-connections")
                .accessibilityValue(model.connections.map { "\($0.config.id.rawValue)=\(connectionStateLabel($0.store.connection))" }.joined(separator: ","))
#endif
            if let warning = model.relayIdentityWarning {
                Button {
                    model.isRelayWarningPresented = true
                } label: {
                    Label("\(warning.label) presented a different Mac identity.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ccAmber)
                        .foregroundStyle(.black)
                }
                .accessibilityIdentifier("relay-identity-warning")
            }
        }
        .sensoryFeedback(.success, trigger: allowFeedbackCount)
        .sensoryFeedback(.warning, trigger: denyFeedbackCount)
        .alert(
            "Couldn't wake session",
            isPresented: Binding(
                get: { wakeError != nil },
                set: { isPresented in
                    if !isPresented { wakeError = nil }
                }
            )
        ) {
            Button("OK") { wakeError = nil }
        } message: {
            Text(wakeError ?? "The session could not be woken.")
        }
        .alert(
            "Mac identity changed",
            isPresented: $model.isRelayWarningPresented
        ) {
            Button("OK", role: .cancel) { model.isRelayWarningPresented = false }
        } message: {
            Text("\(model.relayIdentityWarning?.label ?? "This endpoint") presented a different Mac identity. cc-controller is using the matching endpoint.")
        }
        .alert(
            actionErrorTitle,

            isPresented: Binding(
                get: { model.actionError != nil },
                set: { isPresented in
                    if !isPresented { model.actionError = nil }
                }
            )
        ) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError?.userMessage ?? "The action could not be completed.")
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(
                address: model.connectionAddress,
                relayMode: model.relayMode,
                relayAddresses: model.relayAddressesDraft,
                relayPin: model.relayPinGrouped,
                connectedVia: model.relayMode ? model.connectionLabel : nil,
                latency: model.settings.latency,
                connectionTest: model.settings.connectionTest,
                thisDevice: model.settings.thisDevice,
                pairedDevices: model.settings.pairedDevices,
                appVersion: model.appVersion,
                daemon: model.primaryStore.daemon,
                apiVersion: model.primaryStore.apiVersion,
                isUnpairing: model.isUnpairing,
                lockAfter: SettingsLockInterval(model.lockPolicy.interval),
                onDone: { model.isSettingsPresented = false },
                onTestConnection: { Task { await model.settings.testConnection() } },
                onLockNow: model.lockNow,
                onUnpair: { Task { await model.unpair() } },
                onLockInterval: { model.setLockInterval($0.lockInterval) },
                onRetryDevices: { Task { await model.settings.loadPairedDevices() } },
                onSaveRelayAddresses: model.setRelayAddresses,
                onResetRelayAddresses: model.resetRelayAddresses,
                controllers: model.controllerRows,
                controllerDetail: { id, onRemoved in
                    AnyView(ControllerDetailView(model: model, controllerID: id, onRemoved: onRemoved))
                },
                addController: { onDone in
                    AnyView(AddControllerView(appModel: model, onDone: onDone))
                }
            )
            .onAppear { model.settingsDidAppear() }
            .onDisappear { model.settingsDidDisappear() }
        }
        .sheet(isPresented: $isNewSessionPresented) {
            NewSessionView(store: model.primaryStore) { id, appeared in
                openSession(id)
                if !appeared {
                    sessionNotice = "Session started; it will appear shortly."
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        sessionNotice = nil
                    }
                }
            }
        }
        .onAppear(perform: synchronizeColumnVisibility)
        .onChange(of: model.selectedSession) { _, _ in
            synchronizeColumnVisibility()
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            guard newSizeClass == .regular, model.selectedSession != nil else { return }
            columnVisibility = .detailOnly
        }
    }

    private func splitView() -> some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            SessionsListView(
                sessions: model.primaryStore.sortedSessions,
                sleeping: model.primaryStore.sleeping,
                waking: wakingSessionIDs,
                approvals: model.primaryStore.approvals,
                deciding: model.primaryStore.deciding,
                connection: connection,
                subtitleOverride: model.selectedSession == nil ? nil : "",
                notice: sessionNotice,
                onSessionsLoaded: {
                    await model.requestNotificationAuthorizationAfterSessionsLoaded()
                },
                onOpen: { openSession($0.id) },
                onAllow: { approval in
                    performApprovalDecision(approval, scope: .once)
                },
                onDeny: { approval in
                    performApprovalDeny(approval)
                },
                onRetry: { model.primaryStore.resume() },
                onSettings: { model.isSettingsPresented = true },
                onRefresh: { model.primaryStore.resume() },
                onInterrupt: { session in
                    guard let id = session.id else { return }
                    runAction { await model.primaryStore.interrupt(sessionID: id) }
                },
                onSetApprovalMode: { session, mode in
                    guard let id = session.id else { return }
                    runAction { await model.primaryStore.setApprovalMode(sessionID: id, mode: mode) }
                },
                onCopySessionID: { session in
                    guard let id = session.id else { return }
                    UIPasteboard.general.string = id
                },
                onNewSession: { isNewSessionPresented = true },
                onWake: wakeSession,
                onCopyAttachCommand: { sleeping in
                    UIPasteboard.general.string = "claude attach \(sleeping.shortId)"
                }
            )
        } detail: {
            if let selectedSession = model.selectedSession,
               let selectedConnection = model.connection(for: selectedSession.controllerID) {
                SessionScreen(
                    sessionID: selectedSession.sessionID,
                    store: selectedConnection.store,
                    model: model,
                    approvalsElsewhereCount: approvalsElsewhereCount,
                    onShowApprovalsElsewhere: { columnVisibility = .all }
                )
                .id(selectedSession)
                .onAppear { columnVisibility = .detailOnly }
            } else {
                ContentUnavailableView(
                    "No session selected",
                    systemImage: "rectangle.stack",
                    description: Text("Choose a session to view its transcript.")
                )
                .background(.ccBackground)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(.ccAccent)
        .background(.ccBackground)
    }

    private func openSession(_ id: String?) {
        guard let id else { return }
        model.selectedSession = SessionRef(
            controllerID: model.primaryConnection.config.id,
            sessionID: id
        )
        preferredCompactColumn = .detail
        columnVisibility = .detailOnly
    }

    private func synchronizeColumnVisibility() {
        guard model.selectedSession != nil else {
            columnVisibility = .all
            preferredCompactColumn = .sidebar
            return
        }
        columnVisibility = .detailOnly
    }

    private var approvalsElsewhereCount: Int {
        guard horizontalSizeClass == .regular,
              columnVisibility == .detailOnly,
              let selectedSession = model.selectedSession else { return 0 }
        let sessionIDs = model.primaryStore.approvals.compactMap(\.sessionId)
            .filter { $0 != selectedSession.sessionID }
        return Set(sessionIDs).count
    }

    private var actionErrorTitle: String {
        if case .commandsUnavailable = model.actionError { return "Commands unavailable" }
        return "Action failed"
    }

    private func wakeSession(_ sleeping: SleepingSession) {
        guard wakingSessionIDs.insert(sleeping.id).inserted else { return }
        Task { @MainActor in
            defer { wakingSessionIDs.remove(sleeping.id) }
            do {
                let appeared = try await model.primaryStore.wakeSession(id: sleeping.id)
                guard appeared else {
                    wakeError = "The session did not appear after waking."
                    return
                }
                openSession(sleeping.id)
            } catch {
                wakeError = (error as? APIError)?.daemonMessage ?? error.localizedDescription
            }
        }
    }

    private var connection: SessionsListView.Connection {
        switch model.primaryStore.connection {
        case .live:
            return .live
        case .reconnecting, .connecting:
            return .reconnecting
        case .offline(let lastUpdated, _):
            return .offline(updatedAt: lastUpdated ?? model.primaryStore.lastUpdated ?? .now)
        case .offlineUnreadable(let lastUpdated, _):
            return .unreadable(updatedAt: lastUpdated ?? model.primaryStore.lastUpdated ?? .now)
        case .unauthorized:
            return .offline(updatedAt: model.primaryStore.lastUpdated ?? .now)
        }
    }

    private func performApprovalDecision(_ approval: Approval, scope: ApprovalScope) {
        Task { @MainActor in
            let result = await model.primaryStore.allow(approval, scope: scope)
            switch result {
            case .success:
                allowFeedbackCount += 1
            case .failure(let error):
                model.actionError = error
            }
        }
    }

    private func performApprovalDeny(_ approval: Approval) {
        Task { @MainActor in
            let result = await model.primaryStore.deny(approval)
            switch result {
            case .success:
                denyFeedbackCount += 1
            case .failure(let error):
                model.actionError = error
            }
        }
    }

    private func runAction(_ operation: @escaping () async -> Result<Void, ActionError>) {
        Task {
            if case .failure(let error) = await operation() {
                model.actionError = error
            }
        }
    }

    #if DEBUG
    private func connectionStateLabel(_ state: ConnectionState) -> String {
        switch state {
        case .live: "live"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .offline: "offline"
        case .offlineUnreadable: "offline"
        case .unauthorized: "unauthorized"
        }
    }
    #endif
}
