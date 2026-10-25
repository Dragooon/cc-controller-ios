import Foundation

/// Identifies a session together with the controller that owns it.
public struct SessionRef: Hashable, Sendable, Equatable {
    public let controllerID: ControllerID
    public let sessionID: String

    public init(controllerID: ControllerID, sessionID: String) {
        self.controllerID = controllerID
        self.sessionID = sessionID
    }

    /// Parses the value supplied to `-CCSession`.
    ///
    /// An unqualified value belongs to the primary controller. A qualified
    /// value uses the first colon to separate a controller id from a session id.
    public static func parse(_ value: String, primaryControllerID: ControllerID) -> SessionRef? {
        guard !value.isEmpty else { return nil }
        guard let separator = value.firstIndex(of: ":") else {
            return SessionRef(controllerID: primaryControllerID, sessionID: value)
        }
        let controllerValue = String(value[..<separator])
        let sessionID = String(value[value.index(after: separator)...])
        guard let controllerID = ControllerID(rawValue: controllerValue), !sessionID.isEmpty else { return nil }
        return SessionRef(controllerID: controllerID, sessionID: sessionID)
    }
}
