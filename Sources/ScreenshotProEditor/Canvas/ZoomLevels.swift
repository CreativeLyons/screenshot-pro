import CoreGraphics
import Foundation

/// The editor's discrete zoom levels (1 = 100% = true size).
enum ZoomLevels {
    static let levels: [CGFloat] = [0.25, 0.5, 2.0 / 3.0, 0.75, 1, 2, 3, 4, 6]

    static func next(after zoom: CGFloat) -> CGFloat {
        levels.first { $0 > zoom + 0.001 } ?? levels[levels.count - 1]
    }

    static func previous(before zoom: CGFloat) -> CGFloat {
        levels.last { $0 < zoom - 0.001 } ?? levels[0]
    }

    /// The largest level at which `content` (points at 100%) fits into `available`, never
    /// below the smallest level.
    static func fit(content: CGSize, available: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        let ratio = min(available.width / content.width, available.height / content.height)
        return levels.last { $0 <= ratio + 0.0001 } ?? levels[0]
    }

    static func label(for zoom: CGFloat) -> String {
        let percent = Double(zoom) * 100
        if abs(percent - percent.rounded()) < 0.05 { return "\(Int(percent.rounded())) %" }
        return String(format: "%.1f %%", percent)
    }
}
