// 菜单栏常驻标题（方案 C）：彩色圆点 + 紧凑模型名（如 5.5·medium），不显分数、不显厂牌。
// 用 NSStatusBarButton.attributedTitle 驱动原生宽度。
import AppKit

enum StatusItemTitleBuilder {
    /// 综合最优的 Codex 紧凑名；颜色取其组内名次色（冠军=绿）。
    static func make(snapshot: RadarSnapshot?) -> NSAttributedString {
        // Radar Bench：只有整批读取完整才有榜首（● + 色）。部分批次若已有覆盖完整的 GPT 档，
        // 显示中性色「◐ 型号 n/总数」（已读取完整档中最高，不是全榜冠军）；否则只显示进度。
        if let bench = snapshot?.benchmark, snapshot?.menuBarBest == nil {
            if let leader = snapshot?.provisionalMenuBarBest {
                return NSAttributedString(
                    string: "◐ \(leader.compactName) \(bench.completeCount)/\(bench.expectedCount)",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .kern: -0.3,
                    ]
                )
            }
            return NSAttributedString(
                string: "○ \(bench.completeCount)/\(bench.expectedCount)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }
        guard let best = snapshot?.menuBarBest else {
            return NSAttributedString(
                string: "—",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }

        // 旧 IQ 量纲按阈值取色（只有 IQ≥100 才绿）；Radar Bench 的 score 是 /150 新量纲，旧阈值不适用，用中性蓝。
        let color = best.result.bench != nil ? benchColor : iqColor(best.iq)

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
        return title
    }

    /// Radar Bench 的 tooltip / 辅助功能说明；非 Radar Bench 快照返回 nil（沿用标题文字）。
    /// 明确区分「全榜冠军」与「已读取完整档中最高」，并暴露读取失败、数据过旧和最近成功读取时间。
    static func detail(snapshot: RadarSnapshot?, now: Date = Date()) -> String? {
        guard let bench = snapshot?.benchmark, let snapshot else { return nil }
        let total = bench.expectedCount
        var lines: [String] = []

        if let best = snapshot.menuBarBest {
            lines.append("Radar Bench 全榜榜首：\(best.compactName)\(scoreText(best)) （\(total)/\(total) 档均已完整读取）")
        } else if let leader = snapshot.provisionalMenuBarBest {
            lines.append("已读取完整档中最高：\(leader.compactName)\(scoreText(leader))，不是全榜冠军")
            lines.append("已读取完整档 \(bench.completeCount)/\(total)（已读取 \(bench.observedCount)/\(total)），其余档位未读取或评分覆盖未完整，最高分可能还会变")
        } else {
            lines.append("Radar Bench 读取进行中：完整档 \(bench.completeCount)/\(total)，暂无可显示的型号")
        }
        if bench.failedCount > 0 {
            lines.append("\(bench.failedCount) 个档位最近一次刷新失败，沿用此前读取结果")
        }
        let staleCount = bench.entries.values.filter {
            $0.observation != nil && ($0.fetchedAt.map { now.timeIntervalSince($0) > RadarBenchPolicy.staleAfter } ?? true)
        }.count
        if staleCount > 0 {
            lines.append("\(staleCount) 个档位的读取已超过 \(Int(RadarBenchPolicy.staleAfter / 3600)) 小时，数据可能过时")
        }
        if let read = bench.latestReadAt {
            lines.append("最近成功读取：\(RadarSnapshot.absoluteLabel(read))")
        }
        return lines.joined(separator: "\n")
    }

    private static func scoreText(_ model: ScoredModel) -> String {
        guard let bench = model.result.bench, let score = bench.score else { return "" }
        return String(format: "（%.1f/%.0f 分）", score, bench.scoreMax)
    }

    /// Radar Bench 榜首的中性色（与 DS.blue 同色值）。
    private static let benchColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)

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
