import CCKit
import SwiftUI

enum CCMetrics {
    static let controlCircle: CGFloat = 36
    static let actionHeight: CGFloat = 44
    static let compactActionHeight: CGFloat = 32
    static let minTap: CGFloat = 44
    static let chipHeight: CGFloat = 30
    static let readableContentWidth: CGFloat = 760
    /// Extra space between the lines of text you read at length: replies and your own messages. Body text sits
    /// 22 pt a line by default, which reads cramped in long replies; this opens it to 28.
    static let readingLineSpacing: CGFloat = 6
    /// The gap between paragraphs, lists and code in a reply, kept wider than the gap between lines.
    static let readingBlockSpacing: CGFloat = 14
    static let readingListItemSpacing: CGFloat = 9
}

extension AppAppearance {
    /// Nil follows the phone.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
