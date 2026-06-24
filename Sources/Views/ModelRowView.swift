// 单个模型行：状态点 + 模型名 + 强度 + 通过数 + 分数 + 评分条。
import SwiftUI

struct ModelRowView: View {
    let entry: ModelIQEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 上层
            HStack(spacing: 9) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 6, height: 6)
                Text(entry.name)
                    .font(DF.mono(12, .medium))
                    .tracking(-0.2)
                    .foregroundStyle(DS.text88)
                Text(entry.tag)
                    .font(DF.mono(10, .medium))
                    .foregroundStyle(DS.sec(0.4))
                Spacer(minLength: 8)
                Text(entry.passLabel)
                    .font(DF.mono(11, .medium))
                    .monospacedDigit()
                    .foregroundStyle(DS.sec(0.4))
                Text(entry.scoreLabel)
                    .font(DF.mono(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.status.color)
                    .frame(minWidth: 36, alignment: .trailing)
            }

            // 下层评分条（与模型名左对齐：状态点 6 + gap 9 = 15）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(DS.barTrack)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(entry.status.color)
                        .frame(width: max(0, geo.size.width * entry.barFraction))
                }
            }
            .frame(height: 4)
            .padding(.leading, 15)
        }
        .padding(.top, 6)
        .padding(.horizontal, 15)
        .padding(.bottom, 9)
    }
}
