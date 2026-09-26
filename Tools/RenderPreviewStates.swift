import AppKit
import SwiftUI

@main
struct PreviewStateRenderer {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/preview-renders",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 下面对 VM 的 listMode/onlyFrontier 赋值会通过 didSet 写回 UserDefaults.standard，
        // 污染宿主环境的真实偏好；先存原值，退出（含 throws）时还原。
        let originalListMode = UserDefaults.standard.object(forKey: RadarViewModel.listModeKey)
        let originalOnlyFrontier = UserDefaults.standard.object(forKey: RadarViewModel.onlyFrontierKey)
        defer {
            if let originalListMode {
                UserDefaults.standard.set(originalListMode, forKey: RadarViewModel.listModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RadarViewModel.listModeKey)
            }
            if let originalOnlyFrontier {
                UserDefaults.standard.set(originalOnlyFrontier, forKey: RadarViewModel.onlyFrontierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RadarViewModel.onlyFrontierKey)
            }
        }

        // 「模型推荐」折叠/展开 + 「完整榜单」三个 QA 预览态，均基于同一份固定 fixture
        // （previewSnapshot()，纯函数生成、不含随机性），并显式赋值 listMode/onlyFrontier/
        // expandedRecommendationIDs——这三个字段的默认值来自 UserDefaults.standard，
        // 渲染器进程读到的是宿主环境残留的偏好，不显式覆盖就不是确定性预览。
        let recommendationSnapshot = previewSnapshot()

        let collapsedVM = RadarViewModel.preview(recommendationSnapshot)
        collapsedVM.listMode = .recommendation
        collapsedVM.onlyFrontier = false
        collapsedVM.expandedRecommendationIDs = []

        // 展开态额外开启「只看前沿」，展开 OpenAI 分区第一个折叠行，用来验收
        // ModelRecommendationFrontierFilter 的隐藏条数文案与「显示全部档位」按钮。
        let expandedVM = RadarViewModel.preview(recommendationSnapshot)
        expandedVM.listMode = .recommendation
        expandedVM.onlyFrontier = true
        if let firstGroupID = recommendationSnapshot.recommendationGroups(for: .vendor(.openai)).first?.id {
            expandedVM.expandedRecommendationIDs = [firstGroupID]
        }

        let fullBoardVM = RadarViewModel.preview(recommendationSnapshot)
        fullBoardVM.listMode = .full
        fullBoardVM.onlyFrontier = false

        let states: [(name: String, view: PopoverRootView)] = [
            ("popover", root(collapsedVM)),
            ("loading-initial", root(.preview(isLoading: true))),
            ("error-initial", root(.preview(lastError: "无法连接数据源"))),
            ("model-recommendation-collapsed", root(collapsedVM)),
            ("model-recommendation-expanded", root(expandedVM)),
            ("model-recommendation-full", root(fullBoardVM)),
        ]

        for state in states {
            let url = outputDirectory.appendingPathComponent("\(state.name).png")
            try render(state.view, to: url)
            print(url.path)
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, to url: URL) throws {
        let hostingView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hostingView.frame = NSRect(x: 0, y: 0, width: DS.width, height: 900)
        hostingView.layoutSubtreeIfNeeded()

        // 榜单真实高度依赖 BoardHeightKey 上报（见 PopoverRootView），首次布局只拿到
        // 首帧估算种子；让运行循环走一小段以提交该状态更新，再重新布局才能测到真实内容高度。
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        hostingView.layoutSubtreeIfNeeded()

        let height = hostingView.fittingSize.height
        hostingView.frame = NSRect(x: 0, y: 0, width: DS.width, height: height)

        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.bitmapUnavailable
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }
        try data.write(to: url)
    }

    @MainActor
    private static func root(_ viewModel: RadarViewModel) -> PopoverRootView {
        PopoverRootView(
            vm: viewModel,
            actions: PopoverActions(openWebsite: {}, refresh: {}, quit: {})
        )
    }

    private enum RenderError: Error {
        case bitmapUnavailable
        case pngEncodingFailed
    }
}
