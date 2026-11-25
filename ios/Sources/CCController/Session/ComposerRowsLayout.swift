import SwiftUI

/// Where a composer control sits: the attach button and model chip on the left, the field, stop and send on the right.
enum ComposerSlot {
    case leading
    case field
    case trailing
}

struct ComposerSlotKey: LayoutValueKey {
    static let defaultValue: ComposerSlot = .leading
}

/// The composer's two shapes from one set of subviews. Compact (empty and not in use): one row, attach, the field and
/// send, like the system and Claude apps. Full: the field on its own line above the same bottom row, which gains the
/// model chip. The bottom row is laid out the same way in both, so its buttons don't move; the field slides between
/// the row and the line above, and the card grows upward.
struct ComposerRowsLayout: Layout {
    /// The card's padding. The controls' 44 pt tap frames already hold their visible circles 4 pt in, so a circle
    /// ends up 8 pt from the card's edge and the compact card is 52 pt tall, as in the Claude app.
    static let cardInset: CGFloat = 4
    static let cornerRadius: CGFloat = 26

    var isCompact: Bool
    var spacing: CGFloat = 8
    /// Space between the field's own line and the button row in the full shape.
    var rowSpacing: CGFloat = 2
    /// How far the field's text sits in from the card when nothing is beside it, and above it in the full shape.
    var fieldInset: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? fallbackWidth(subviews)
        let arrangement = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let frame = arrangement.frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    /// Without a proposed width (which a composer always gets), the controls side by side with a modest field.
    private func fallbackWidth(_ subviews: Subviews) -> CGFloat {
        var total: CGFloat = 0
        for subview in subviews where subview[ComposerSlotKey.self] != .field {
            total += subview.sizeThatFits(.unspecified).width + spacing
        }
        return total + 200
    }

    private struct Arrangement {
        var frames: [CGRect]
        var height: CGFloat
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var leadingIndices: [Int] = []
        var trailingIndices: [Int] = []
        var fieldIndex: Int?
        for index in subviews.indices {
            switch subviews[index][ComposerSlotKey.self] {
            case .leading: leadingIndices.append(index)
            case .trailing: trailingIndices.append(index)
            case .field: fieldIndex = index
            }
        }

        // The trailing controls (stop, send) keep their size and sit against the right edge.
        var trailingSizes: [Int: CGSize] = [:]
        var trailingWidth: CGFloat = 0
        for index in trailingIndices {
            let size = subviews[index].sizeThatFits(.unspecified)
            trailingSizes[index] = size
            trailingWidth += size.width
        }
        trailingWidth += CGFloat(trailingIndices.count) * spacing

        // The leading controls take what they need, left to right; the model chip, last, truncates to fit.
        var leadingSizes: [Int: CGSize] = [:]
        var leadingWidth: CGFloat = 0
        for index in leadingIndices {
            let room = max(0, width - trailingWidth - leadingWidth)
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let size = ideal.width <= room ? ideal : subviews[index].sizeThatFits(ProposedViewSize(width: room, height: ideal.height))
            leadingSizes[index] = size
            leadingWidth += size.width + spacing
        }

        var rowHeight: CGFloat = 0
        for size in leadingSizes.values { rowHeight = max(rowHeight, size.height) }
        for size in trailingSizes.values { rowHeight = max(rowHeight, size.height) }

        var rowTop: CGFloat = 0
        if let fieldIndex {
            if isCompact {
                let fieldLeft = leadingIndices.isEmpty ? fieldInset : leadingWidth
                let fieldWidth = max(0, width - fieldLeft - trailingWidth)
                let fieldSize = subviews[fieldIndex].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
                rowHeight = max(rowHeight, fieldSize.height)
                frames[fieldIndex] = CGRect(x: fieldLeft, y: (rowHeight - fieldSize.height) / 2, width: fieldWidth, height: fieldSize.height)
            } else {
                let fieldWidth = max(0, width - fieldInset * 2)
                let fieldSize = subviews[fieldIndex].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
                frames[fieldIndex] = CGRect(x: fieldInset, y: fieldInset, width: fieldWidth, height: fieldSize.height)
                rowTop = fieldInset + fieldSize.height + rowSpacing
            }
        }

        var x: CGFloat = 0
        for index in leadingIndices {
            let size = leadingSizes[index] ?? .zero
            frames[index] = CGRect(x: x, y: rowTop + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            x += size.width + spacing
        }
        var right = width
        for index in trailingIndices.reversed() {
            let size = trailingSizes[index] ?? .zero
            right -= size.width
            frames[index] = CGRect(x: right, y: rowTop + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            right -= spacing
        }
        return Arrangement(frames: frames, height: rowTop + rowHeight)
    }
}
