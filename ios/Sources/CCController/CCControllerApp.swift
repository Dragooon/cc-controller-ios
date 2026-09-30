import Foundation
import Observation
import SwiftUI

struct NativeSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let state: String
    let project: String?
    let action: String?
}

struct NativeState: Codable, Sendable {
    let sessions: [NativeSession]
}

struct NativeBootstrap: Codable, Sendable {
    let state: NativeState
}

private enum NativeAPIError: Error {
    case response
}

private func fetchState(from serverURL: URL, bearer: String) async throws -> NativeState {
    var request = URLRequest(url: serverURL.appending(path: "/api/bootstrap"))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !bearer.isEmpty {
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw NativeAPIError.response
        }
        return try JSONDecoder().decode(NativeBootstrap.self, from: data).state
    } catch {
        var fallback = URLRequest(url: serverURL.appending(path: "/api/state"))
        fallback.setValue("application/json", forHTTPHeaderField: "Accept")
        if !bearer.isEmpty {
            fallback.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: fallback)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw error
        }
        return try JSONDecoder().decode(NativeState.self, from: data)
    }
}

@MainActor
@Observable
final class AppModel {
    var sessions: [NativeSession] = []
    var selectedID: NativeSession.ID?
    var connectionError: String?
    var serverURL = URL(string: "http://127.0.0.1:47832")!
    var bearer = ""
    var colorScheme: ColorScheme?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if let value = argumentValue("-CCServer", in: arguments), let url = URL(string: value) {
            serverURL = url
        }
        bearer = argumentValue("-CCBearer", in: arguments) ?? ""
        switch argumentValue("-CCColorScheme", in: arguments) {
        case "light": colorScheme = .light
        case "dark": colorScheme = .dark
        default: colorScheme = nil
        }
    }

    func load() async {
        do {
            let state = try await fetchState(from: serverURL, bearer: bearer)
            sessions = state.sessions
            selectedID = selectedID.flatMap { id in state.sessions.contains(where: { $0.id == id }) ? id : nil }
                ?? state.sessions.first?.id
            connectionError = nil
        } catch {
            connectionError = "Can't reach the Mac (\(error.localizedDescription))"
        }
    }

    func session(for id: NativeSession.ID?) -> NativeSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    private func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@main
struct CCControllerApp: App {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            SessionsView(model: model)
                .preferredColorScheme(model.colorScheme)
        }
    }
}

struct SessionsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                if let error = model.connectionError {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Color("Secondary"))
                        .accessibilityIdentifier("connection-error")
                }
                ForEach(model.sessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                    .accessibilityIdentifier("session-\(session.id)")
                }
            }
            .navigationTitle("Sessions")
            .scrollContentBackground(.hidden)
            .background(Color("Background"))
            .refreshable { await model.load() }
        } detail: {
            if let session = model.session(for: model.selectedID) {
                SessionDetail(session: session)
            } else {
                ContentUnavailableView("No sessions", systemImage: "rectangle.stack", description: Text("No Claude Code sessions are running on this Mac."))
                    .accessibilityIdentifier("empty-detail")
            }
        }
        .task { await model.load() }
        .tint(Color("Accent"))
        .background(Color("Background"))
    }
}

private struct SessionRow: View {
    let session: NativeSession

    private var stateLabel: String {
        session.state.replacingOccurrences(of: "_", with: " ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(glyph)
                .font(.title2.weight(.medium))
                .foregroundStyle(stateColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.headline)
                    .foregroundStyle(Color("Label"))
                    .lineLimit(2)
                Text(session.project.map { "\($0) · \(stateLabel)" } ?? stateLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color("Secondary"))
                if let action = session.action {
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(Color("Tertiary"))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(Color("Card"))
    }

    private var glyph: String {
        switch session.state {
        case "working": return "✻"
        case "needs_you": return "●"
        default: return "○"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case "working": return Color("Accent")
        case "needs_you": return Color("Red")
        default: return Color("Tertiary")
        }
    }
}

private struct SessionDetail: View {
    let session: NativeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.name)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color("Label"))
                .accessibilityIdentifier("selected-session-name")
            Text(session.state.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.subheadline)
                .foregroundStyle(Color("Secondary"))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(Color("Background"))
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
