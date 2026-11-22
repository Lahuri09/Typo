import CoreGraphics

public struct PanelPosition: Equatable, Sendable {
    public let horizontal: CGFloat
    public let vertical: CGFloat

    // Measure the panel's travel from the top-left, so edge positions survive resizing.
    public init(horizontal: CGFloat, vertical: CGFloat) {
        self.horizontal = Self.clamped(horizontal)
        self.vertical = Self.clamped(vertical)
    }

    public init(center: CGPoint, size: CGSize, in bounds: CGRect) {
        let roomX = bounds.width - size.width
        let roomY = bounds.height - size.height
        self.init(horizontal: roomX > 0 ? (center.x - bounds.minX - size.width / 2) / roomX : 0.5,
                  vertical: roomY > 0 ? (bounds.maxY - center.y - size.height / 2) / roomY : 0.5)
    }

    public func windowFrame(size: CGSize, in bounds: CGRect, avoiding obstacle: CGRect? = nil) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let preferred = CGRect(x: bounds.minX + horizontal * (bounds.width - width),
                               y: bounds.minY + (1 - vertical) * (bounds.height - height),
                               width: width, height: height)
        guard let obstacle else { return preferred }
        let blocked = obstacle.insetBy(dx: -4, dy: -4).intersection(bounds)
        guard !preferred.intersection(blocked).isEmpty else { return preferred }

        let clearAreas = [
            CGRect(x: bounds.minX, y: bounds.minY, width: blocked.minX - bounds.minX, height: bounds.height),
            CGRect(x: blocked.maxX, y: bounds.minY, width: bounds.maxX - blocked.maxX, height: bounds.height),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: blocked.minY - bounds.minY),
            CGRect(x: bounds.minX, y: blocked.maxY, width: bounds.width, height: bounds.maxY - blocked.maxY)
        ]
        let candidates = clearAreas.filter { !$0.isEmpty }.map { area in
            let width = min(preferred.width, area.width)
            let height = min(preferred.height, area.height)
            return CGRect(x: min(max(preferred.minX, area.minX), area.maxX - width),
                          y: min(max(preferred.minY, area.minY), area.maxY - height),
                          width: width, height: height)
        }
        // The chooser can scroll vertically when a collision leaves too little space.
        return candidates.min { first, second in
            if first.width != second.width { return first.width > second.width }
            if first.height != second.height { return first.height > second.height }
            return hypot(first.minX - preferred.minX, first.minY - preferred.minY)
                < hypot(second.minX - preferred.minX, second.minY - preferred.minY)
        } ?? preferred
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}
