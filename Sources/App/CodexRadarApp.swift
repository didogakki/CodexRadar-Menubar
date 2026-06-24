// 入口 —— 纯菜单栏 App：无 WindowGroup，仅空 Settings 场景，UI 全部由 AppDelegate 驱动。
import SwiftUI

@main
struct CodexRadarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
