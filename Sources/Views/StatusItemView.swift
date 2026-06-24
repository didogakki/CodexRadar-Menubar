// 菜单栏常驻标题：用 NSStatusBarButton.attributedTitle 驱动原生宽度，
// 避免 SwiftUI 子视图被 NSStatusItem 折叠成只露出状态圆点。
import AppKit

enum StatusItemTitleBuilder {
    static func make(snapshot: RadarSnapshot?) -> NSAttributedString {
        guard let entry = snapshot?.models.first else {
            return NSAttributedString(
                string: "—",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: "● ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: entry.status.statusItemColor,
                .baselineOffset: 1,
            ]
        ))
        title.append(NSAttributedString(
            string: entry.scoreLabel,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
                .foregroundColor: entry.status.statusItemColor,
            ]
        ))
        title.append(NSAttributedString(
            string: " \(entry.tag)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return title
    }
}

private extension HealthStatus {
    var statusItemColor: NSColor {
        switch self {
        case .green:  return NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1.000, green: 0.831, blue: 0.149, alpha: 1)
        case .red:    return NSColor(srgbRed: 1.000, green: 0.271, blue: 0.227, alpha: 1)
        }
    }
}
