// 设计 Token —— 颜色 / 字体 / 度量集中一处，严格对应 README「Design Tokens」。
import SwiftUI

extension Color {
    /// 0xRRGGBB + 透明度。
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// 颜色与度量。
enum DS {
    // 容器
    static let containerBG = Color(hex: 0x242426)
    static let border = Color.white.opacity(0.10)
    static let divider = Color.white.opacity(0.08)
    static let groupLine = Color.white.opacity(0.06)
    static let width: CGFloat = 344
    static let cornerRadius: CGFloat = 13

    // 文字
    static let text92 = Color.white.opacity(0.92)
    static let text90 = Color.white.opacity(0.9)
    static let text88 = Color.white.opacity(0.88)
    static let text82 = Color.white.opacity(0.82)
    /// 次要文字基色 rgba(235,235,245,a)。
    static func sec(_ a: Double) -> Color { Color(hex: 0xEBEBF5, alpha: a) }

    // 排名 / 健康色（同一套标准，组内名次）
    static let green = Color(hex: 0x30D158)
    static let yellow = Color(hex: 0xFFD60A)
    static let orange = Color(hex: 0xFF9F0A)
    static let red = Color(hex: 0xFF453A)
    static let blue = Color(hex: 0x0A84FF)

    /// 排名配色：1 绿 / 2 黄 / 3 橙 / 4 红（及以后均红）。
    static let rankColors: [Color] = [green, yellow, orange, red]
    static func rankColor(_ index: Int) -> Color { rankColors[min(max(index, 0), rankColors.count - 1)] }

    /// IQ 阈值配色：≥100 绿 / 90–99 黄 / 80–89 橙 / <80 红。
    /// 与名次配色（rankColor）相互独立，不复用同一变量。
    static func iqColor(_ iq: Double) -> Color {
        switch iq {
        case 100...:  return green
        case 90..<100: return yellow
        case 80..<90:  return orange
        default:       return red
        }
    }

    // 进度条 / hover
    static let barTrack = Color.white.opacity(0.07)
    static let rowHover = Color.white.opacity(0.05)
}

/// 字体 —— 正文 SF Pro（.default），数字/模型名 SF Mono（.monospaced）。
enum DF {
    static func mono(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func pro(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}
