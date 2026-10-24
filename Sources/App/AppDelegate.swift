// 菜单栏宿主：NSStatusItem + NSPopover(.transient) + NSHostingController，
// 后台轮询、⌘O/⌘R 快捷键与各菜单动作。
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let viewModel = RadarViewModel()
    private var pollTimer: Timer?
    private var keyMonitor: Any?
    private var statusItemCancellable: AnyCancellable?

    private let websiteURL = URL(string: "https://codexradar.com/")!
    private let pollInterval: TimeInterval = 1800  // 30 分钟

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // 无 Dock 图标（配合 LSUIElement）
        setupStatusItem()
        setupPopover()

        // 单元测试以本 App 为宿主：宿主启动时不真实联网、不写观测缓存，测试自己用 stub 驱动 ViewModel。
        guard NSClassFromString("XCTestCase") == nil else { return }
        Task { await viewModel.refresh(trigger: .launch) }
        startPolling()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        // 菜单栏管理器（Thaw 等）按 AX identifier / title 识别图标，并用 identifier 拼系统的位置键；
        // 标题里的型号会变，所以 identifier 固定且与 autosaveName 一致，动态文字只放进 AXValue，
        // 避免每次换型号被当成新图标，位置写入也不会落到错误的键上。
        statusItem.autosaveName = "com.codexradar.app.statusItem"
        button.setAccessibilityIdentifier("com.codexradar.app.statusItem")

        updateStatusItemTitle()
        statusItemCancellable = viewModel.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItemTitle() }
            }
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }
        let title = StatusItemTitleBuilder.make(snapshot: viewModel.snapshot)
        let detail = StatusItemTitleBuilder.detail(snapshot: viewModel.snapshot)
        // 标题没变时 tooltip（失败 / 过旧 / 读取时间）仍可能变，所以先单独更新。
        if button.toolTip != detail { button.toolTip = detail }
        guard !button.attributedTitle.isEqual(to: title) else {
            if let detail { button.setAccessibilityValue("\(title.string)。\(detail)") }
            return
        }
        button.attributedTitle = title
        button.setAccessibilityTitle("CodexRadar")
        button.setAccessibilityValue(detail.map { "\(title.string)。\($0)" } ?? title.string)
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)

        let actions = PopoverActions(
            openWebsite: { [weak self] in self?.openWebsite() },
            refresh: { [weak self] in self?.manualRefresh() },
            quit: { [weak self] in self?.quitApp() }
        )
        let root = PopoverRootView(vm: viewModel, actions: actions)
        let hosting = NSHostingController(rootView: root)
        // 弹窗在「加载中」状态就被创建，NSPopover 默认只按首帧尺寸定型、之后不会跟着内容长大：
        // 数据到位后视图仍停在两百多点高，榜单被压成两三行。让宿主控制器把 SwiftUI 的真实尺寸
        // 同步成 preferredContentSize，弹窗才会随内容重新测量。
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    // MARK: - 弹窗开合

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            installKeyMonitor()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
    }

    // ⌘O / ⌘R：弹窗显示时拦截键盘事件（比 popover 内 SwiftUI keyboardShortcut 更可靠）。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown,
                  event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": self.openWebsite(); return nil
            case "r": self.manualRefresh(); return nil
            default:  return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - 轮询

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // 后台轮询只补读缺失/过期（≥3h）的档位，不整批重扫。
            Task { await self?.viewModel.refresh(trigger: .background) }
        }
    }

    // MARK: - 菜单动作

    private func openWebsite() {
        NSWorkspace.shared.open(websiteURL)
        popover.performClose(nil)
    }

    private func manualRefresh() {
        Task { await viewModel.refresh(trigger: .manual) }   // 不收起弹窗，展示加载态
    }

    private func quitApp() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSApp.terminate(nil)
    }
}
