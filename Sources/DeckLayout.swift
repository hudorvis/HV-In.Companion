import Foundation

struct DeckLayout {
    let gap: CGFloat
    let side: CGFloat
    let center: CGPoint

    init(size: CGSize, columns: Int, rows: Int, corner: CGFloat, centerOffset: CGPoint = .zero) {
        let gap = min(7, max(1, min(size.width / CGFloat(columns), size.height / CGFloat(rows)) * 0.12))
        self.gap = gap
        let center = CGPoint(x: size.width / 2 + centerOffset.x, y: size.height / 2 + centerOffset.y)
        self.center = center

        let halfWidth = min(center.x, size.width - center.x)
        let halfHeight = min(center.y, size.height - center.y)
        let horizontalGaps = CGFloat(columns - 1) * gap
        let verticalGaps = CGFloat(rows - 1) * gap
        func keySize(halfWidth: CGFloat, halfHeight: CGFloat) -> CGFloat {
            min((2 * halfWidth - horizontalGaps) / CGFloat(columns),
                (2 * halfHeight - verticalGaps) / CGFloat(rows))
        }

        let initialSide = keySize(halfWidth: halfWidth, halfHeight: halfHeight)
        let deckWidth = CGFloat(columns) * initialSide + horizontalGaps
        let deckHeight = CGFloat(rows) * initialSide + verticalGaps
        let deck = CGRect(x: center.x - deckWidth / 2, y: center.y - deckHeight / 2,
                          width: deckWidth, height: deckHeight)
        let toggle = CGRect(x: size.width - corner, y: 0, width: corner, height: corner)
        if corner > 0, deck.intersects(toggle) {
            // Reduce the grid symmetrically to clear the toggle without shifting its centre.
            let clearWidth = min(halfWidth, toggle.minX - center.x - gap)
            let clearHeight = min(halfHeight, center.y - toggle.maxY - gap)
            side = max(1, max(keySize(halfWidth: clearWidth, halfHeight: halfHeight),
                              keySize(halfWidth: halfWidth, halfHeight: clearHeight)))
        } else {
            side = max(1, initialSide)
        }
    }
}
