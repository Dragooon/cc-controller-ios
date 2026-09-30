import SwiftUI

#if DEBUG
struct MockGate<Content: View>: View {
    @ViewBuilder let content: () -> Content

    private var requestedScreen: MockScreen? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-CCMock"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else {
            return nil
        }
        return MockScreen(rawValue: ProcessInfo.processInfo.arguments[index + 1])
    }

    private var colorScheme: ColorScheme? {
        switch argumentValue("-CCColorScheme") {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        Group {
            if let requestedScreen {
                MockScreenView(screen: requestedScreen)
            } else {
                content()
            }
        }
        .preferredColorScheme(colorScheme)
    }

    private func argumentValue(_ name: String) -> String? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: name),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else {
            return nil
        }
        return ProcessInfo.processInfo.arguments[index + 1]
    }
}
#else
struct MockGate<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
#endif

enum MockScreen: String, CaseIterable, Identifiable {
    case sessions
    case sessionsEmpty = "sessions-empty"
    case sessionsOffline = "sessions-offline"
    case sessionsReconnecting = "sessions-reconnecting"
    case sessionIdle = "session-idle"
    case sessionWorking = "session-working"
    case sessionApprovals = "session-approvals"
    case sessionTerminalApproval = "session-terminal-approval"
    case composerSlash = "composer-slash"
    case composerAttachments = "composer-attachments"
    case composerKeyboard = "composer-keyboard"
    case toolDetail = "tool-detail"
    case toolDetailEdit = "tool-detail-edit"
    case subagent
    case inspector
    case settings
    case onboardingWelcome = "onboarding-welcome"
    case onboardingConnect = "onboarding-connect"
    case onboardingPair = "onboarding-pair"
    case onboardingFaceID = "onboarding-faceid"
    case lock
    case privacyCover = "privacy-cover"

    var id: String { rawValue }

    var isBuilt: Bool {
        switch self {
        case .sessions, .sessionsEmpty, .sessionsOffline, .sessionsReconnecting,
             .sessionWorking, .composerSlash, .composerAttachments, .composerKeyboard,
             .inspector, .settings, .onboardingWelcome, .onboardingConnect,
             .onboardingPair, .onboardingFaceID, .lock, .privacyCover: true
        default: false
        }
    }
}

private struct MockScreenView: View {
    let screen: MockScreen

    var body: some View {
        Group {
            switch screen {
            case .sessions:
                SessionsMocks.sessions
            case .sessionsEmpty:
                SessionsMocks.empty
            case .sessionsOffline:
                SessionsMocks.offline
            case .sessionsReconnecting:
                SessionsMocks.reconnecting
            case .sessionIdle:
                SessionMocks.idle
            case .sessionWorking:
                BottomStackMocks.working
            case .composerSlash:
                BottomStackMocks.slash
            case .composerAttachments:
                BottomStackMocks.attachments
            case .composerKeyboard:
                BottomStackMocks.keyboard
            case .toolDetail:
                SessionMocks.toolDetail
            case .toolDetailEdit:
                SessionMocks.toolDetailEdit
            case .subagent:
                SessionMocks.subagent
            case .inspector:
                SheetMocks.inspector
            case .settings:
                SheetMocks.settings
            case .onboardingWelcome:
                SheetMocks.onboardingWelcome
            case .onboardingConnect:
                SheetMocks.onboardingConnect
            case .onboardingPair:
                SheetMocks.onboardingPair
            case .onboardingFaceID:
                SheetMocks.onboardingFaceID
            case .lock:
                SheetMocks.lock
            case .privacyCover:
                SheetMocks.privacyCover
            default:
                MockPlaceholder(screen: screen)
            }
        }
        .accessibilityIdentifier("mock-ready")
    }
}

struct MockPlaceholder: View {
    let screen: MockScreen

    var body: some View {
        ContentUnavailableView(
            screen.rawValue,
            systemImage: "rectangle.dashed",
            description: Text("This design mock is planned for a later unit.")
        )
        .foregroundStyle(.ccSecondary)
        .background(.ccBackground)
    }
}
