// 品牌雷达图标 —— 同心圆 + 绿色扫描点 + 绿色扫描线（对应设计稿内联 SVG，viewBox 0 0 14 14）。
import SwiftUI

struct RadarGlyph: View {
    var size: CGFloat = 15

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 14.0          // 设计坐标 14 单位 → 实际像素
            func scaled(_ v: CGFloat) -> CGFloat { v * s }
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func circle(center cx: CGFloat, _ cy: CGFloat, r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * s, y: (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
            }

            // 外圈 r6
            ctx.stroke(circle(center: 7, 7, r: 6), with: .color(.white.opacity(0.35)), lineWidth: scaled(1))
            // 内圈 r3
            ctx.stroke(circle(center: 7, 7, r: 3), with: .color(.white.opacity(0.5)), lineWidth: scaled(1))
            // 扫描线 (7,7) -> (12,4)
            var sweep = Path()
            sweep.move(to: point(7, 7))
            sweep.addLine(to: point(12, 4))
            ctx.stroke(sweep, with: .color(DS.green),
                       style: StrokeStyle(lineWidth: scaled(1), lineCap: .round))
            // 中心扫描点 r1.4
            ctx.fill(circle(center: 7, 7, r: 1.4), with: .color(DS.green))
        }
        .frame(width: size, height: size)
    }
}
