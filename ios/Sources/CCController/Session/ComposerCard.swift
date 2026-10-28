import SwiftUI

struct ComposerCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}
