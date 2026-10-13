import Foundation
import CoreGraphics

/// Arrangement of all active displays in global Quartz coordinates (origin at the top-left of
/// the main display, y growing downward), used to keep the pointer on a real screen.
public struct DisplayLayout: Sendable, Equatable {
    public var displays: [CGRect]

    public init(displays: [CGRect]) {
        self.displays = displays.isEmpty ? [CGRect(x: 0, y: 0, width: 1470, height: 956)] : displays
    }

    /// Reads the live display arrangement (main display first).
    public static func current() -> DisplayLayout {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return DisplayLayout(displays: [CGDisplayBounds(CGMainDisplayID())])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return DisplayLayout(displays: [CGDisplayBounds(CGMainDisplayID())])
        }
        let main = CGMainDisplayID()
        let sorted = ids.prefix(Int(count)).sorted { ($0 == main ? 0 : 1) < ($1 == main ? 0 : 1) }
        return DisplayLayout(displays: sorted.map { CGDisplayBounds($0) })
    }

    public var main: CGRect { displays[0] }

    /// Display containing `point`, or the nearest one.
    public func display(containing point: CGPoint) -> CGRect {
        if let hit = displays.first(where: { $0.contains(point) }) {
            return hit
        }
        return displays.min(by: { distanceSquared(point, $0) < distanceSquared(point, $1) }) ?? main
    }

    /// Clamps `point` onto the nearest display so the pointer never leaves the desktop, and
    /// slides along edges between displays instead of sticking at the union's bounding box.
    public func clamp(_ point: CGPoint) -> CGPoint {
        if displays.contains(where: { $0.contains(point) }) {
            return point
        }
        var best = point
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for rect in displays {
            // maxX/maxY are exclusive for `contains`, so stay a hair inside.
            let x = min(max(point.x, rect.minX), rect.maxX - 0.5)
            let y = min(max(point.y, rect.minY), rect.maxY - 0.5)
            let d = (x - point.x) * (x - point.x) + (y - point.y) * (y - point.y)
            if d < bestDistance {
                bestDistance = d
                best = CGPoint(x: x, y: y)
            }
        }
        return best
    }

    private func distanceSquared(_ p: CGPoint, _ rect: CGRect) -> CGFloat {
        let x = min(max(p.x, rect.minX), rect.maxX)
        let y = min(max(p.y, rect.minY), rect.maxY)
        return (x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)
    }
}
