// 底部菜单项块：hover 蓝色高亮 + 快捷键。
import SwiftUI

struct MenuListView: View {
    let actions: PopoverActions

    var body: some View {
        VStack(spacing: 0) {
            MenuRow(title: "打开网站", shortcut: "⌘O", action: actions.openWebsite)
            MenuRow(title: "立即刷新", shortcut: "⌘R", action: actions.refresh)
            MenuRow(title: "测试通知", action: actions.testNotification)

            Rectangle()
                .fill(DS.divider)
                .frame(height: 0.5)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)

            MenuRow(title: "退出 CodexRadar", action: actions.quit)
        }
        .padding(.horizontal, 6)
    }
}

private struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    var chevron: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(DF.pro(13, .regular))
                .foregroundStyle(hovering ? Color.white : DS.text90)
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut)
                    .font(DF.mono(12, .regular))
                    .foregroundStyle(hovering ? Color.white.opacity(0.85) : DS.sec(0.45))
            }
            if chevron {
                Text("›")
                    .font(DF.pro(13, .regular))
                    .foregroundStyle(hovering ? Color.white : DS.sec(0.45))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? DS.blue : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
