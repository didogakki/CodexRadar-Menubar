// 分组：组标题（名 + 右侧细线）+ 组内行，一律按 IQ 降序；推荐结论由顶部场景推荐区承担。
import SwiftUI

struct GroupSectionView: View {
    let title: String
    let models: [ScoredModel]   // 已按展示顺序排列（解析层决定）
    var unavailable: Bool = false   // 该组数据抓取失败时显示提示行
    var isLocalEstimate: Bool = false   // Codex 回退到 current.json 本地估算时明确标注
    var onlyFrontier: Bool = false      // 只看性价比前沿：隐藏被压制的行
    var protectedID: String? = nil      // 菜单栏当前档位：被压制也不隐藏，避免菜单栏结论在榜单里消失

    var body: some View {
        if unavailable {
            VStack(alignment: .leading, spacing: 0) {
                header(hiddenCount: 0)
                Text("因网页格式变化，Claude 数据提取失败")
                    .font(DF.pro(11, .regular))
                    .foregroundStyle(DS.sec(0.45))
                    .padding(.horizontal, 15)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }
        } else if !models.isEmpty {
            // 性价比判定只在本组内做，整组算一次后分发给各行（见 CostEfficiency）。
            // 判定始终基于**全量** models：先过滤再判定会让前沿基准漂移（隐藏掉压制者后，
            // 被压制的行反而会翻身变成前沿）。过滤只作用于展示。
            let verdicts = CostEfficiency.verdicts(in: models)
            // 名次色沿用全量列表里的原始位次，切换开关不会让同一行改变颜色。
            let rows = Array(models.enumerated()).filter { isVisible($0.element, verdicts: verdicts) }
            VStack(alignment: .leading, spacing: 0) {
                header(hiddenCount: models.count - rows.count)
                ForEach(rows, id: \.element.id) { index, model in
                    GroupRowView(model: model, color: DS.rankColor(index), verdict: verdicts[model.id])
                        // 被压制却因推荐/菜单栏豁免而留下的行：淡化，表明它本该被这个开关藏起来。
                        .opacity(onlyFrontier && isDominated(model, verdicts: verdicts) ? 0.55 : 1)
                }
            }
        }
    }

    /// 缺价格或耗时的行没有判定（价格显示中性灰），不算被压制。
    private func isDominated(_ model: ScoredModel, verdicts: [String: CostVerdict]) -> Bool {
        verdicts[model.id]?.isDominated ?? false
    }

    /// 开关关闭时全展示；开启时按 FrontierFilter 的规则过滤。
    private func isVisible(_ model: ScoredModel, verdicts: [String: CostVerdict]) -> Bool {
        guard onlyFrontier else { return true }
        return FrontierFilter.isVisible(model, verdicts: verdicts, protectedID: protectedID)
    }

    /// 组标题：名 + 占满剩余宽度的细线 + 右侧列标注（本地估算回退时明确标出，
    /// 「只看前沿」隐藏了行时追加隐藏条数）。
    private func header(hiddenCount: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(DF.mono(10, .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.72))
            Rectangle()
                .fill(DS.groupLine)
                .frame(height: 0.5)
            Text(isLocalEstimate ? "本地估算" : (hiddenCount > 0 ? "IQ · 隐藏 \(hiddenCount)" : "IQ"))
                .font(DF.pro(9, .regular))
                .foregroundStyle(isLocalEstimate ? DS.orange.opacity(0.8) : DS.sec(0.35))
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }
}
