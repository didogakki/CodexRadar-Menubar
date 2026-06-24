// 头部块：品牌行 + 24h 重置胶囊 + 「智商检测于」+「距今」。
import SwiftUI

struct HeaderView: View {
    @ObservedObject var vm: RadarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 第一行：图标 + 品牌名 + 重置胶囊
            HStack(spacing: 8) {
                RadarGlyph(size: 15)
                Text("CodexRadar")
                    .font(DF.pro(13, .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                resetPill
            }

            // 第二行：智商检测于 {本地时间}（失败时红色错误文案）
            Group {
                if let err = vm.lastError {
                    Text("更新失败：\(err)")
                        .font(DF.pro(11, .regular))
                        .foregroundStyle(DS.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        Text("智商检测于")
                            .font(DF.pro(11, .regular))
                            .foregroundStyle(DS.sec(0.4))
                        Text(vm.snapshot?.updatedAtLocal ?? "—")
                            .font(DF.mono(11, .medium))
                            .foregroundStyle(DS.sec(0.7))
                    }
                }
            }
            .padding(.top, 9)

            // 第三行：距今 {relTime}
            if vm.snapshot != nil, vm.lastError == nil {
                HStack(spacing: 0) {
                    Text("距今 ").foregroundStyle(DS.sec(0.4))
                    Text(vm.relativeLabel).foregroundStyle(DS.sec(0.62))
                }
                .font(DF.pro(11, .regular))
                .padding(.top, 3)
            }
        }
        .padding(.top, 11)
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }

    private var resetPill: some View {
        let highlight = vm.snapshot?.highlightReset ?? false
        let label = vm.snapshot?.reset24hLabel ?? "—"
        return HStack(spacing: 5) {
            Circle()
                .fill(highlight ? DS.green : DS.sec(0.45))
                .frame(width: 6, height: 6)
                .shadow(color: highlight ? DS.green.opacity(0.6) : .clear, radius: highlight ? 3.5 : 0)
            Text("24h 重置 \(label)")
                .font(DF.mono(11, .semibold))
                .foregroundStyle(highlight ? DS.green : DS.sec(0.6))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 9)
        .background(Capsule().fill(highlight ? DS.pillHighlightBG : DS.pillNeutralBG))
    }
}
