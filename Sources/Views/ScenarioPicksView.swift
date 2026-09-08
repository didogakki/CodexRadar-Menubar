// 场景推荐区：把「日常开发」「难题攻坚」两组结论直接摆在榜单上方。
// 每个场景两行——主推荐 + 备选；型号名不截断，价格 / IQ 右对齐成列便于纵向比较。
//
// IQ 取 InsightItem 自身的综合 IQ（comprehensive_points），也就是推荐排序真正依据的那个值；
// 榜单行显示的是 efficiency 单点 IQ，两者量级不同（例如 sol/ultra 综合 105.1 但单点 100.9），
// 用综合 IQ 才不会出现「第一名的数字比第二名小」。
import SwiftUI

struct ScenarioPicksView: View {
    let groups: [InsightGroup]   // 已按服务端顺序过滤好的场景分组

    /// 推荐区只展示这两个决策场景（后台自动化 / 跑龙虾仍以行内 chip 呈现），顺序即展示顺序。
    static let displayKeys = ["daily_development", "hard_problems"]

    /// 从快照中取出要展示的场景分组（缺失或空组自动跳过）。
    static func groups(in snapshot: RadarSnapshot) -> [InsightGroup] {
        displayKeys.compactMap { key in
            snapshot.insights.first { $0.key == key && !$0.items.isEmpty }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Rectangle().fill(DS.divider).frame(height: 0.5).padding(.horizontal, 15)
                }
                scenario(group)
            }
        }
    }

    private func scenario(_ group: InsightGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(group.items.prefix(2).enumerated()), id: \.element.id) { index, item in
                pickRow(item, groupTitle: group.title, isPrimary: index == 0)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(group))
    }

    private func pickRow(_ item: InsightItem, groupTitle: String, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            Text(isPrimary ? groupTitle : "备选")
                .font(DF.pro(isPrimary ? 10 : 9, isPrimary ? .semibold : .regular))
                .foregroundStyle(isPrimary ? DS.sceneColor(groupTitle) : DS.sec(0.3))
                .frame(width: 56, alignment: .leading)
            Text("\(item.model) \(item.effort)")
                .font(DF.mono(isPrimary ? 12 : 11, isPrimary ? .semibold : .regular))
                .foregroundStyle(isPrimary ? DS.text92 : DS.sec(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let cost = item.averageCostUSD, cost > 0 {
                Text(String(format: "$%.1f", cost))
                    .font(DF.mono(10, .regular))
                    .monospacedDigit()
                    .foregroundStyle(DS.sec(0.4))
                    .fixedSize()
            }
            HStack(spacing: 3) {
                Text("IQ").font(DF.pro(8, .regular)).foregroundStyle(DS.sec(0.35))
                Text(String(format: "%.1f", item.iq))
                    .font(DF.mono(isPrimary ? 12 : 11, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.iqColor(item.iq))
            }
            .fixedSize()
        }
    }

    private func accessibilityLabel(_ group: InsightGroup) -> String {
        let picks = group.items.prefix(2).enumerated().map { index, item in
            "\(index == 0 ? "首选" : "备选")\(item.model) \(item.effort)，IQ \(String(format: "%.1f", item.iq))"
        }
        return "\(group.title)：\(picks.joined(separator: "；"))"
    }
}
