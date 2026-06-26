// 弹窗根视图：头部 → 分隔 → 分组榜单 → 分隔 → 操作。
import SwiftUI

/// 菜单项动作集合（由 AppDelegate 注入）。
struct PopoverActions {
    var openWebsite: () -> Void
    var refresh: () -> Void
    var quit: () -> Void
}

struct PopoverRootView: View {
    @ObservedObject var vm: RadarViewModel
    let actions: PopoverActions

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(vm: vm)

            Rectangle().fill(DS.divider).frame(height: 0.5)

            content

            Rectangle().fill(DS.divider).frame(height: 0.5)
                .padding(.top, 6).padding(.bottom, 4)

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
    private var content: some View {
        if let snapshot = vm.snapshot {
            board(snapshot)
                .opacity(vm.isLoading ? 0.5 : 1)   // 刷新时降低透明度（骨架感）
                .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
        } else if vm.lastError == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("加载中…").font(DF.pro(12, .regular)).foregroundStyle(DS.sec(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            Color.clear.frame(height: 8)   // 首次即失败：错误已在头部显示
        }
    }

    /// Codex / Claude Code 两组，各自按综合分降序，组内名次决定行配色。
    private func board(_ snapshot: RadarSnapshot) -> some View {
        VStack(spacing: 0) {
            GroupSectionView(family: .codex, models: snapshot.codexGroup)
            GroupSectionView(
                family: .claude,
                models: snapshot.claudeGroup,
                unavailable: snapshot.claudeStatus == .unavailable
            )
        }
        .padding(.bottom, 2)
    }
}

#if DEBUG
#Preview("正常") { previewRoot(vm: .preview(previewSnapshot())) }
#Preview("加载态") { previewRoot(vm: .preview(isLoading: true)) }
#Preview("错误态") { previewRoot(vm: .preview(lastError: "无法连接 codexradar.com")) }

private func previewRoot(vm: RadarViewModel) -> PopoverRootView {
    PopoverRootView(
        vm: vm,
        actions: PopoverActions(openWebsite: {}, refresh: {}, quit: {})
    )
}

func previewSnapshot() -> RadarSnapshot {
    let raw: [ModelResult] = [
        ModelResult(name: "gpt-5.5", depth: "medium", iq: 87,  passed: 7, tasks: 12, cost: 23.9, timeMinutes: 85,  family: .codex,  isReference: false),
        ModelResult(name: "gpt-5.5", depth: "high",   iq: 93,  passed: 7, tasks: 12, cost: 29.4, timeMinutes: 107, family: .codex,  isReference: false),
        ModelResult(name: "gpt-5.4", depth: "xhigh",  iq: 101, passed: 8, tasks: 12, cost: 23.4, timeMinutes: 246, family: .codex,  isReference: false),
        ModelResult(name: "gpt-5.5", depth: "xhigh",  iq: 96,  passed: 7, tasks: 12, cost: 43.3, timeMinutes: 201, family: .codex,  isReference: false),
        ModelResult(name: "opus-4.8", depth: "high",  iq: 108, passed: 8, tasks: 12, cost: 63.0, timeMinutes: 210, family: .claude, isReference: true),
        ModelResult(name: "opus-4.8", depth: "max",   iq: 99,  passed: 6, tasks: 12, cost: 115,  timeMinutes: 384, family: .claude, isReference: true),
    ]
    let scored = (try? RadarParser.scoreAndSort(raw)) ?? []
    return RadarSnapshot(all: scored, updatedAt: Date().addingTimeInterval(-14 * 3600 - 37 * 60))
}
#endif
