import CCKit
import Foundation
import Network
import UIKit

struct RelayEndpointDiagnostic: Identifiable, Equatable {
    let id: String
    let endpoint: URL
    let label: String
    let status: Status

    enum Status: Equatable {
        case macNotConnected
        case relayReachable
        case notReachable
        case localNetworkDenied
        case identityChanged
    }

    var address: String {
        endpoint.host.map { "\($0):\(endpoint.port ?? 0)" } ?? endpoint.absoluteString
    }

    var statusText: String {
        switch status {
        case .macNotConnected: "Mac not connected to relay"
        case .relayReachable: "Relay reachable"
        case .notReachable: "Not reachable"
        case .localNetworkDenied: "Local Network access is off"
        case .identityChanged: "Mac identity changed"
        }
    }
}

struct RelayDiagnostics: Equatable {
    let endpoints: [RelayEndpointDiagnostic]
    let summary: String

    var identityChanged: Bool {
        endpoints.contains { $0.status == .identityChanged }
    }
}

func relayEndpointStatusText(_ status: RelayEndpointDiagnostic.Status) -> String {
    switch status {
    case .macNotConnected: "Mac not connected to relay"
    case .relayReachable: "Relay reachable"
    case .notReachable: "Not reachable"
    case .localNetworkDenied: "Local Network access is off"
    case .identityChanged: "Mac identity changed"
    }
}

func parseRelayAddresses(_ text: String) -> [URL]? {
    let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { return [] }
    let urls = lines.compactMap { URL(string: $0) }
    guard urls.count == lines.count,
          urls.allSatisfy(isValidRelayAddress) else { return nil }
    return urls
}

func isValidRelayAddress(_ url: URL) -> Bool {
    ControllerConfig.isValidRelayAddress(url)
}

func relayAddressesText(_ urls: [URL]) -> String {
    urls.map(\.absoluteString).joined(separator: "\n")
}

func openLocalNetworkSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
