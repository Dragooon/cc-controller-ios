import SwiftUI

extension ShapeStyle where Self == Color {
    static var ccBackground: Color { Color(CCTheme.assetName("Background")) }
    static var ccCard: Color { Color(CCTheme.assetName("Card")) }
    static var ccBubble: Color { Color(CCTheme.assetName("Bubble")) }
    static var ccSeparator: Color { Color(CCTheme.assetName("Separator")) }
    static var ccLabel: Color { Color(CCTheme.assetName("Label")) }
    static var ccSecondary: Color { Color(CCTheme.assetName("Secondary")) }
    static var ccTertiary: Color { Color(CCTheme.assetName("Tertiary")) }
    static var ccAccent: Color { Color(CCTheme.assetName("AccentColor")) }
    static var ccGreen: Color { Color(CCTheme.assetName("Green")) }
    static var ccRed: Color { Color(CCTheme.assetName("Red")) }
    static var ccBlue: Color { Color(CCTheme.assetName("Blue")) }
    static var ccAmber: Color { Color(CCTheme.assetName("Amber")) }
}
