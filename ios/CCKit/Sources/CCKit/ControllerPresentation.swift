import Foundation

/// The composer controls enabled by a controller's advertised capabilities.
public struct ComposerCapabilities: Equatable, Sendable {
    public let canAttach: Bool
    public let canRunCommands: Bool

    public init(controllerCapabilities: Set<ControllerCapability>) {
        canAttach = controllerCapabilities.contains(.files)
        canRunCommands = controllerCapabilities.contains(.commands)
    }
}
