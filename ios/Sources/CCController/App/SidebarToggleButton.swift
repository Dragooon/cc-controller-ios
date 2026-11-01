import SwiftUI

/// Opens and closes the large-mode sidebar. It lives in the bar of whichever column is showing.
struct SidebarToggleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Toggle sidebar", systemImage: "sidebar.left")
        }
        .accessibilityIdentifier("sidebar-toggle")
    }
}

extension View {
    /// Keeps a side column's items in its own horizontal bar, wherever the app sits on the display.
    @ViewBuilder
    func horizontalToolbarInSideColumn() -> some View {
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
    }
}
