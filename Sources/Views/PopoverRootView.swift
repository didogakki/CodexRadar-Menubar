// 弹窗根视图 —— 垂直堆叠：头部 → 分隔 → IQ 列头 → 模型列表 → 分隔 → 菜单。
import SwiftUI

/// 菜单项动作集合（由 AppDelegate 注入）。
struct PopoverActions {
    var openWebsite: () -> Void
    var refresh: () -> Void
    var testNotification: () -> Void
    var quit: () -> Void
}

struct PopoverRootView: View {
    @ObservedObject var vm: RadarViewModel
    let actions: PopoverActions

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(vm: vm)

            hairline(top: 2, bottom: 2)

            // IQ 列头（右对齐，压在分数列上方）
            HStack {
                Spacer()
                Text("IQ · 满分 150")
                    .font(DF.mono(10, .medium))
                    .tracking(0.3)
                    .foregroundStyle(DS.sec(0.35))
            }
            .padding(.horizontal, 15)
            .padding(.top, 8)

            modelSection

            hairline(top: 4, bottom: 6)

            MenuListView(actions: actions)
        }
        .padding(.vertical, 6)
        .frame(width: DS.width)
        .background(
            ZStack {
                VisualEffectView()
                DS.containerBG.opacity(0.72)   // 叠 #242426 让毛玻璃透出细微底色
            }
        )
    }

    @ViewBuilder
    private var modelSection: some View {
        if let snapshot = vm.snapshot {
            VStack(spacing: 0) {
                ForEach(snapshot.models) { ModelRowView(entry: $0) }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            .opacity(vm.isLoading ? 0.5 : 1)   // 刷新时降低透明度（骨架感）
            .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
        } else if vm.lastError == nil {
            // 首次加载占位
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("加载中…").font(DF.pro(12, .regular)).foregroundStyle(DS.sec(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            // 首次即失败：留出空间，错误已在头部红字显示
            Color.clear.frame(height: 8)
        }
    }

    private func hairline(top: CGFloat, bottom: CGFloat) -> some View {
        Rectangle()
            .fill(DS.divider)
            .frame(height: 0.5)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }
}

#if DEBUG
#Preview("成功态") {
    previewRoot(vm: .preview(previewSnapshot()))
}

#Preview("加载态 - 首次") {
    previewRoot(vm: .preview(isLoading: true))
}

#Preview("加载态 - 刷新") {
    previewRoot(vm: .preview(previewSnapshot(), isLoading: true))
}

#Preview("错误态 - 首次失败") {
    previewRoot(vm: .preview(lastError: "无法连接 codexradar.com"))
}

#Preview("错误态 - 保留缓存") {
    previewRoot(vm: .preview(previewSnapshot(), lastError: "请求超时，请稍后重试"))
}

private func previewRoot(vm: RadarViewModel) -> PopoverRootView {
    PopoverRootView(
        vm: vm,
        actions: PopoverActions(
            openWebsite: {},
            refresh: {},
            testNotification: {},
            quit: {}
        )
    )
}

private func previewSnapshot() -> RadarSnapshot {
    let entries = [
        ModelIQEntry(name: "gpt-5.5", tag: "xhigh",  score: 125,  passed: 10, tasks: 12, status: .green),
        ModelIQEntry(name: "gpt-5.5", tag: "high",   score: 87.5, passed: 7,  tasks: 12, status: .yellow),
        ModelIQEntry(name: "gpt-5.4", tag: "xhigh",  score: 87.5, passed: 7,  tasks: 12, status: .yellow),
        ModelIQEntry(name: "gpt-5.5", tag: "medium", score: 75,   passed: 6,  tasks: 12, status: .red),
    ]

    return RadarSnapshot(
        models: entries,
        updatedAt: Date(),
        reset24hPercent: 18
    )
}
#endif
