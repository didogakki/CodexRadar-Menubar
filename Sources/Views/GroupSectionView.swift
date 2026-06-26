// 方案 B 分组：组标题（名 + 右侧细线）+ 组内按综合分排序的行，组内名次决定颜色。
import SwiftUI

struct GroupSectionView: View {
    let family: ModelFamily
    let models: [ScoredModel]   // 已按综合分降序（组内排名分）
    var unavailable: Bool = false   // 该组数据抓取失败时显示提示行

    var body: some View {
        if unavailable {
            VStack(alignment: .leading, spacing: 0) {
                header
                Text("因网页格式变化，Claude 数据提取失败")
                    .font(DF.pro(11, .regular))
                    .foregroundStyle(DS.sec(0.45))
                    .padding(.horizontal, 15)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }
        } else if !models.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    GroupRowView(model: model, color: DS.rankColor(index))
                }
            }
        }
    }

    /// 组标题：名 + 占满剩余宽度的细线 + 右侧列标注。
    private var header: some View {
        HStack(spacing: 7) {
            Text(family.title)
                .font(DF.mono(10, .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.72))
            Rectangle()
                .fill(DS.groupLine)
                .frame(height: 0.5)
            // 右侧两列标注：IQ · 组内分（分数仅组内可比，避免与另一组横比误读）
            Text("IQ · 组内分")
                .font(DF.pro(9, .regular))
                .foregroundStyle(DS.sec(0.35))
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }
}
