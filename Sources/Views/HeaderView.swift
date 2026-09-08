// 头部块：雷达图标 + 品牌名 + 右侧两行（绝对检测时间戳 / 距今相对时间）。
import SwiftUI

struct HeaderView: View {
    @ObservedObject var vm: RadarViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            RadarGlyph(size: 15)
            Text("CodexRadar")
                .font(DF.pro(13, .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            rightBlock
        }
        .padding(.top, 11)
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var rightBlock: some View {
        if let err = vm.lastError, vm.snapshot == nil {
            // 首次即失败：右侧显示红色错误（多行）。
            Text("更新失败：\(err)")
                .font(DF.pro(10, .regular))
                .foregroundStyle(DS.red)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 180, alignment: .trailing)
        } else if vm.snapshot != nil {
            VStack(alignment: .trailing, spacing: 1) {
                Text(vm.snapshot?.checkedAtLabel ?? "—")
                    .font(DF.mono(10, .regular))
                    .foregroundStyle(DS.sec(0.5))
                Text("距今 \(vm.relativeLabel)")
                    .font(DF.pro(9, .regular))
                    .foregroundStyle(DS.sec(0.32))
                // 保留上一次好快照 / 本次刷新失败时，明确标出榜单不是刚拉到的。
                if vm.lastError != nil {
                    Text("未更新，展示上次结果")
                        .font(DF.pro(9, .regular))
                        .foregroundStyle(DS.orange.opacity(0.85))
                }
            }
        }
    }
}
