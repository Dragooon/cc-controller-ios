import CCKit
import SwiftUI
import UIKit

struct MainSplitView: View {
    @Bindable var model: AppModel
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var allowFeedbackCount = 0
    @State private var denyFeedbackCount = 0

    var body: some View {
        splitView()
        .sensoryFeedback(.success, trigger: allowFeedbackCount)
        .sensoryFeedback(.warning, trigger: denyFeedbackCount)
        .alert(
            "Action failed",
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
                latency: model.settings.latency,
                connectionTest: model.settings.connectionTest,
                thisDevice: model.settings.thisDevice,
                pairedDevices: model.settings.pairedDevices,
                appVersion: model.appVersion,
                daemon: model.store.daemon,
                apiVersion: model.store.apiVersion,
                isUnpairing: model.isUnpairing,
                lockAfter: SettingsLockInterval(model.lockPolicy.interval),
                onDone: { model.isSettingsPresented = false },
                onTestConnection: { Task { await model.settings.testConnection() } },
                onLockNow: model.lockNow,
                onUnpair: { Task { await model.unpair() } },
                onLockInterval: { model.setLockInterval($0.lockInterval) },
                onRetryDevices: { Task { await model.settings.loadPairedDevices() } }
            )
            .onAppear { model.settingsDidAppear() }
            .onDisappear { model.settingsDidDisappear() }
        }
    }

    private func splitView() -> some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            SessionsListView(
                sessions: model.store.sortedSessions,
                approvals: model.store.approvals,
                deciding: model.store.deciding,
                connection: connection,
                subtitleOverride: model.selectedSessionID == nil ? nil : "",
                onSessionsLoaded: {
                    await model.requestNotificationAuthorizationAfterSessionsLoaded()
                },
                onOpen: {
                    model.selectedSessionID = $0.id
                    preferredCompactColumn = .detail
                },
                onAllow: { approval in
                    performApprovalDecision(approval, scope: .once)
                },
                onDeny: { approval in
                    performApprovalDeny(approval)
                },
                onRetry: { model.store.resume() },
                onSettings: { model.isSettingsPresented = true },
                onRefresh: { model.store.resume() },
                onInterrupt: { session in
                    guard let id = session.id else { return }
                    runAction { await model.store.interrupt(sessionID: id) }
                },
                onSetApprovalMode: { session, mode in
                    guard let id = session.id else { return }
                    runAction { await model.store.setApprovalMode(sessionID: id, mode: mode) }
                },
                onCopySessionID: { session in
                    guard let id = session.id else { return }
                    UIPasteboard.general.string = id
                }
            )
        } detail: {
            if let selectedSessionID = model.selectedSessionID {
                SessionScreen(sessionID: selectedSessionID, model: model)
            } else {
                ContentUnavailableView(
                    "No session selected",
                    systemImage: "rectangle.stack",
                    description: Text("Choose a session to view its transcript.")
                )
                .background(.ccBackground)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.ccAccent)
        .background(.ccBackground)
    }

    private var connection: SessionsListView.Connection {
        switch model.store.connection {
        case .live:
            return .live
        case .reconnecting, .connecting:
            return .reconnecting
        case .offline(let lastUpdated, _):
            return .offline(updatedAt: lastUpdated ?? model.store.lastUpdated ?? .now)
        case .unauthorized:
            return .offline(updatedAt: model.store.lastUpdated ?? .now)
        }
    }

    private func performApprovalDecision(_ approval: Approval, scope: ApprovalScope) {
        Task { @MainActor in
            let result = await model.store.allow(approval, scope: scope)
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
            let result = await model.store.deny(approval)
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
}
