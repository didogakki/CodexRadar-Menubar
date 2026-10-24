// 头部块：雷达图标 + 品牌名 + 右侧几行（成功读取时间 / 距今与来源评分时间 / 读取进度与失败提示）。
// 「读取」是本地成功拉取的时间；「评分」是接口给出的最近一次评分时间，缺失就不显示，绝不拿当前时间顶替。
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

    private var secondLine: String {
        var text = "距今 \(vm.relativeLabel)"
        if let graded = vm.snapshot?.gradedAtLabel { text += " · 评分 \(graded)" }
        return text
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
                Text("读取 \(vm.snapshot?.checkedAtLabel ?? "—")")
                    .font(DF.mono(10, .regular))
                    .foregroundStyle(DS.sec(0.5))
                Text(secondLine)
                    .font(DF.pro(9, .regular))
                    .foregroundStyle(DS.sec(0.32))
                if let progress = vm.progressLabel {
                    Text(progress)
                        .font(DF.pro(9, .regular))
                        .foregroundStyle(DS.blue.opacity(0.9))
                }
                // 本次刷新有失败 / 暂停时，明确标出原因，榜单里沿用的行带「缓存」角标。
                if let notice = vm.lastError {
                    Text(notice)
                        .font(DF.pro(9, .regular))
                        .foregroundStyle(DS.orange.opacity(0.85))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 240, alignment: .trailing)
        }
    }
}
