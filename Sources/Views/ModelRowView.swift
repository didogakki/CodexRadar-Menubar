// 密集单行：圆点(排名色) + 模型名(窄窗中间截断) + 思考档 + 推荐场景 chip + ×N 性价比角标 + 价格(性价比配色) + IQ(阈值色)。
import SwiftUI

struct GroupRowView: View {
    let model: ScoredModel
    let color: Color            // 组内名次色
    let verdict: CostVerdict?   // 组内性价比结论；nil = 花费/耗时数据不全，不参与判定

    enum RowMetrics {
        static let verticalPadding: CGFloat = 8
        static let horizontalPadding: CGFloat = 15
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(model.result.name)
                .font(DF.mono(12, .semibold))
                .foregroundStyle(DS.text92)
                .lineLimit(1)
                .truncationMode(.middle)   // 窄窗下中间截断，保留可辨识的前后缀
            Text(model.result.depth)
                .font(DF.mono(11, .medium))
                .foregroundStyle(DS.sec(0.5))
                .fixedSize()
                .layoutPriority(1)
            if !model.recommendedIn.isEmpty {
                recommendedChips
            }
            Spacer(minLength: 8)
            if let badge = verdict?.badgeLabel {
                Text(badge)
                    .font(DF.mono(9, .semibold))
                    .foregroundStyle(DS.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.orange.opacity(0.16)))
                    .fixedSize()
                    .layoutPriority(1)
            }
            if let cost = model.validCostLabel {
                Text(cost)
                    .font(DF.mono(11, verdict == nil ? .regular : .medium))
                    .monospacedDigit()
                    .foregroundStyle(costColor)
                    .fixedSize()
                    .layoutPriority(1)
            }
            HStack(spacing: 3) {
                Text("IQ").font(DF.pro(8, .regular)).foregroundStyle(DS.sec(0.4))
                Text(model.iqLabel)
                    .font(DF.mono(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.iqColor(model.iq))
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.vertical, RowMetrics.verticalPadding)
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 推荐场景标记：按场景配色（日常开发蓝 / 难题攻坚紫，见 DS.sceneColor），全部展示不折叠——
    /// 一个档位同时命中两个场景是常态，折成 "+1" 等于把第二个场景藏起来。
    private var recommendedChips: some View {
        HStack(spacing: 3) {
            ForEach(model.recommendedIn, id: \.self) { name in
                Text(name)
                    .font(DF.pro(8, .medium))
                    .foregroundStyle(DS.sceneColor(name))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(DS.sceneColor(name).opacity(0.16)))
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    /// 价格配色：性价比前沿绿、被同组更便宜且不更弱的档位压制则橙；
    /// 花费或耗时数据不全（verdict 为 nil）不参与判定，保持原来的中性灰。
    private var costColor: Color {
        guard let verdict else { return DS.sec(0.45) }
        return verdict.isDominated ? DS.orange : DS.green
    }

    private var accessibilityLabel: String {
        var parts = ["\(model.result.name) \(model.result.depth)", "IQ \(model.iqLabel)"]
        if let cost = model.validCostLabel { parts.append("价格 \(cost)") }
        if !model.recommendedIn.isEmpty {
            parts.append("推荐用于\(model.recommendedIn.joined(separator: "、"))")
        }
        if let dominator = verdict?.dominator, let badge = verdict?.badgeLabel {
            parts.append("比同组的 \(dominator.result.name) \(dominator.result.depth) 贵 \(badge.dropFirst())倍且不更强")
        }
        return parts.joined(separator: "，")
    }
}
