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
    /// 22 pt a line by default, which reads cramped in long replies; this opens it to 26, about one and a half
    /// times the text size. More than that and the lines of a paragraph stop reading as one block.
    static let readingLineSpacing: CGFloat = 4
    /// Headings are short, so their lines sit closer than running text.
    static let headingLineSpacing: CGFloat = 2
    /// Extra room above a heading, on top of the gap between blocks, so it belongs to what follows it.
    static let headingTopSpacing: CGFloat = 6
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
