import Foundation

/// Launch-configured presentation switches. Launch arguments take precedence over saved defaults.
enum CCTheme: String, Sendable {
    case classic
    case linen

    static let current: Self = resolve(
        arguments: ProcessInfo.processInfo.arguments,
        defaults: UserDefaults.standard
    )

    static func bootstrap() {
        _ = current
    }

    static func assetName(_ name: String) -> String {
        current == .linen ? "Linen/\(name)" : name
    }

    private static func resolve(arguments: [String], defaults: UserDefaults) -> Self {
        if let value = argumentValue("-CCTheme", in: arguments), let theme = Self(rawValue: value) {
            return theme
        }
        return Self(rawValue: defaults.string(forKey: "cc-controller.theme") ?? "") ?? .classic
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

enum CCNewSessionButtonMode: String, Sendable {
    case classic
    case floating

    static let current: Self = resolve(
        arguments: ProcessInfo.processInfo.arguments,
        defaults: UserDefaults.standard
    )

    static func bootstrap() {
        _ = current
    }

    private static func resolve(arguments: [String], defaults: UserDefaults) -> Self {
        if let value = argumentValue("-CCNewSessionButton", in: arguments), let mode = Self(rawValue: value) {
            return mode
        }
        return Self(rawValue: defaults.string(forKey: "cc-controller.newSessionButton") ?? "") ?? .classic
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

enum CCProseFont: String, Sendable {
    case system
    case serif

    static let current: Self = resolve(
        arguments: ProcessInfo.processInfo.arguments,
        defaults: UserDefaults.standard
    )

    static func bootstrap() {
        _ = current
    }

    private static func resolve(arguments: [String], defaults: UserDefaults) -> Self {
        if let value = argumentValue("-CCProseFont", in: arguments), let font = Self(rawValue: value) {
            return font
        }
        return Self(rawValue: defaults.string(forKey: "cc-controller.proseFont") ?? "") ?? .system
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
