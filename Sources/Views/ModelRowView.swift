// 方案 B 单行：圆点(排名色) + 模型名 + 思考档 + 综合分(排名色) + 进度条(排名色)。
import SwiftUI

struct GroupRowView: View {
    let model: ScoredModel
    let color: Color          // 组内名次色

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(model.result.name)
                    .font(DF.mono(12, .semibold))
                    .foregroundStyle(DS.text92)
                Text(model.result.depth)
                    .font(DF.mono(11, .medium))
                    .foregroundStyle(DS.sec(0.5))
                Spacer(minLength: 8)
                // IQ 智力分（按 IQ 阈值上色，独立于名次色）
                HStack(spacing: 3) {
                    Text("IQ").font(DF.pro(8, .regular)).foregroundStyle(DS.sec(0.4))
                    Text(model.iqLabel)
                        .font(DF.mono(13, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DS.iqColor(model.iq))
                }
                .padding(.trailing, 10)
                Text(model.scoreLabel)
                    .font(DF.mono(15, .bold))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(color)
            }

            // 进度条（与圆点对齐缩进：圆点 6 + gap 8 = 14）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(DS.barTrack)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * model.barFraction))
                }
            }
            .frame(height: 5)
            .padding(.leading, 14)   // 与模型名对齐：圆点 6 + gap 8
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 15)    // 行内 9 + 组边距 6，与卡片内容缩进一致
    }
}
