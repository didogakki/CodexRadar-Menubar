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
    static let width: CGFloat = 330
    static let cornerRadius: CGFloat = 13

    // 文字
    static let text90 = Color.white.opacity(0.9)
    static let text88 = Color.white.opacity(0.88)
    /// 次要文字基色 rgba(235,235,245,a)。
    static func sec(_ a: Double) -> Color { Color(hex: 0xEBEBF5, alpha: a) }

    // 状态色
    static let green = Color(hex: 0x30D158)
    static let yellow = Color(hex: 0xFFD426)
    static let red = Color(hex: 0xFF453A)
    static let blue = Color(hex: 0x0A84FF)

    // 评分条 / 胶囊
    static let barTrack = Color.white.opacity(0.07)
    static let pillNeutralBG = Color.white.opacity(0.06)
    static let pillHighlightBG = Color(hex: 0x30D158, alpha: 0.15)
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

extension HealthStatus {
    var color: Color {
        switch self {
        case .green:  return DS.green
        case .yellow: return DS.yellow
        case .red:    return DS.red
        }
    }
}
