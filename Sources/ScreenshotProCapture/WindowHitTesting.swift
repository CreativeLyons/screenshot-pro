import CoreGraphics
import Foundation

/// One entry of the on-screen window list, as plain data.
struct WindowInfo: Equatable, Sendable {
    var id: CGWindowID
    var processID: pid_t
    var layer: Int
    var alpha: Double
    /// Frame in Quartz global points.
    var bounds: CGRect
    var title: String?
    var ownerName: String?

    /// Title for labels and capture details: the window title, else the owner's name.
    var displayTitle: String? {
        if let title, !title.isEmpty { return title }
        if let ownerName, !ownerName.isEmpty { return ownerName }
        return nil
    }
}

/// Window detection for the overlay and the window list. Parsing, filtering and hit testing
/// are pure; only `onScreenWindows()` talks to the window server.
enum WindowHitTesting {
    /// Windows smaller than this (points, either side) are ignored: tiny helper windows.
    static let minimumSide: CGFloat = 20

    /// The on-screen windows front to back (CGWindowListCopyWindowInfo is documented to return
    /// them in z-order). Titles need Screen Recording permission.
    static func onScreenWindows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return parse(list as? [[String: Any]] ?? [])
    }

    /// Converts window list dictionaries, keeping their order. Entries without an id or
    /// bounds are dropped.
    static func parse(_ list: [[String: Any]]) -> [WindowInfo] {
        list.compactMap { entry in
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return WindowInfo(
                id: number,
                processID: (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: bounds,
                title: entry[kCGWindowName as String] as? String,
                ownerName: entry[kCGWindowOwnerName as String] as? String
            )
        }
    }

    /// Windows the user can pick: normal layer, visible, not tiny, not ours. Order is kept.
    static func selectable(_ windows: [WindowInfo], excludingPID ownPID: pid_t) -> [WindowInfo] {
        windows.filter { w in
            w.layer == 0 && w.alpha > 0.01 && w.processID != ownPID
                && w.bounds.width >= minimumSide && w.bounds.height >= minimumSide
        }
    }

    /// Windows for the "Capture Window from List" menu: selectable ones that have a title.
    static func listable(_ windows: [WindowInfo], excludingPID ownPID: pid_t) -> [WindowInfo] {
        selectable(windows, excludingPID: ownPID).filter { !($0.title ?? "").isEmpty }
    }

    /// The front-most window containing a Quartz point (`windows` ordered front to back).
    static func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.bounds.contains(point) }
    }

    /// Sorts windows into the window server's z-order (front first). Windows missing from
    /// `zOrder` go last, keeping their relative order.
    static func sorted<T>(_ windows: [T], byZOrder zOrder: [CGWindowID], id: (T) -> CGWindowID) -> [T] {
        var rank: [CGWindowID: Int] = [:]
        for (i, wid) in zOrder.enumerated() where rank[wid] == nil { rank[wid] = i }
        return windows.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max, rb = rank[id(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
