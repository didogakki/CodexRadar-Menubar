// 菜单栏常驻标题（方案 C）：彩色圆点 + 紧凑模型名（如 5.5·medium），不显分数、不显厂牌。
// 用 NSStatusBarButton.attributedTitle 驱动原生宽度。
import AppKit

enum StatusItemTitleBuilder {
    /// 综合最优的 Codex 紧凑名；颜色取其组内名次色（冠军=绿）。
    static func make(snapshot: RadarSnapshot?) -> NSAttributedString {
        guard let best = snapshot?.menuBarBest else {
            return NSAttributedString(
                string: "—",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }

        let color = iqColor(best.iq)  // 圆点+文字色由推荐型号 IQ 决定（只有 IQ≥100 才绿）

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: "● ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: color,
                .baselineOffset: 1,
            ]
        ))
        title.append(NSAttributedString(
            string: best.compactName,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color,
                .kern: -0.3,
            ]
        ))
        title.append(NSAttributedString(
            string: " IQ \(best.iqLabel)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color,
                .kern: -0.3,
            ]
        ))
        return title
    }

    /// IQ 阈值配色（NSColor 版，与 DS.iqColor 同阈值同色值）：
    /// ≥100 #30D158 / 90–99 #FFD60A / 80–89 #FF9F0A / <80 #FF453A。
    private static func iqColor(_ iq: Double) -> NSColor {
        switch iq {
        case 100...:   return NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)
        case 90..<100: return NSColor(srgbRed: 1.000, green: 0.839, blue: 0.039, alpha: 1)
        case 80..<90:  return NSColor(srgbRed: 1.000, green: 0.624, blue: 0.039, alpha: 1)
        default:       return NSColor(srgbRed: 1.000, green: 0.271, blue: 0.227, alpha: 1)
        }
    }
}
