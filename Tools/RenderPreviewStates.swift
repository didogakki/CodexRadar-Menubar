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

        let states: [(name: String, view: PopoverRootView)] = [
            ("popover", root(.preview(previewSnapshot()))),
            ("loading-initial", root(.preview(isLoading: true))),
            ("error-initial", root(.preview(lastError: "无法连接数据源"))),
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
