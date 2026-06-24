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

        let states: [(name: String, viewModel: RadarViewModel)] = [
            ("success", .preview(snapshot())),
            ("loading-initial", .preview(isLoading: true)),
            ("loading-refresh", .preview(snapshot(), isLoading: true)),
            ("error-initial", .preview(lastError: "无法连接 codexradar.com")),
            ("error-cached", .preview(snapshot(), lastError: "请求超时，请稍后重试")),
        ]

        for state in states {
            let url = outputDirectory.appendingPathComponent("\(state.name).png")
            try render(root(viewModel: state.viewModel), to: url)
            print(url.path)
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, to url: URL) throws {
        let hostingView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hostingView.frame = NSRect(x: 0, y: 0, width: DS.width, height: 900)
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
    private static func root(viewModel: RadarViewModel) -> PopoverRootView {
        PopoverRootView(
            vm: viewModel,
            actions: PopoverActions(
                openWebsite: {},
                refresh: {},
                testNotification: {},
                quit: {}
            )
        )
    }

    private static func snapshot() -> RadarSnapshot {
        RadarSnapshot(
            models: [
                ModelIQEntry(name: "gpt-5.5", tag: "xhigh",  score: 125,  passed: 10, tasks: 12, status: .green),
                ModelIQEntry(name: "gpt-5.5", tag: "high",   score: 87.5, passed: 7,  tasks: 12, status: .yellow),
                ModelIQEntry(name: "gpt-5.4", tag: "xhigh",  score: 87.5, passed: 7,  tasks: 12, status: .yellow),
                ModelIQEntry(name: "gpt-5.5", tag: "medium", score: 75,   passed: 6,  tasks: 12, status: .red),
            ],
            updatedAt: Date(),
            reset24hPercent: 18
        )
    }

    private enum RenderError: Error {
        case bitmapUnavailable
        case pngEncodingFailed
    }
}
