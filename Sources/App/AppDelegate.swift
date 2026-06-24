// 菜单栏宿主：NSStatusItem + NSPopover(.transient) + NSHostingController，
// 后台轮询、本地通知、⌘O/⌘R 快捷键与各菜单动作。
import AppKit
import Combine
import SwiftUI
import UserNotifications

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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task { await viewModel.refresh() }
        startPolling()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)

        updateStatusItemTitle()
        statusItemCancellable = viewModel.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItemTitle() }
            }
    }

    private func updateStatusItemTitle() {
        statusItem.button?.attributedTitle = StatusItemTitleBuilder.make(snapshot: viewModel.snapshot)
        statusItem.length = NSStatusItem.variableLength
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)

        let actions = PopoverActions(
            openWebsite: { [weak self] in self?.openWebsite() },
            refresh: { [weak self] in self?.manualRefresh() },
            testNotification: { [weak self] in self?.sendTestNotification() },
            quit: { [weak self] in self?.quitApp() }
        )
        let root = PopoverRootView(vm: viewModel, actions: actions)
        popover.contentViewController = NSHostingController(rootView: root)
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
            Task { await self?.viewModel.refresh() }
        }
    }

    // MARK: - 菜单动作

    private func openWebsite() {
        NSWorkspace.shared.open(websiteURL)
        popover.performClose(nil)
    }

    private func manualRefresh() {
        Task { await viewModel.refresh() }   // 不收起弹窗，展示加载态
    }

    private func sendTestNotification() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "CodexRadar"
            content.body = "测试通知：降智雷达运行正常。"
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func quitApp() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSApp.terminate(nil)
    }
}
