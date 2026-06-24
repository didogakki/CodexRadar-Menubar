// 视图层使用的领域模型（已与解码层解耦）。
import Foundation

/// 模型健康状态 —— 决定状态点 / 分数 / 评分条的颜色。
enum HealthStatus: String, Codable {
    case green, yellow, red
}

/// 单条模型评分。满分 150（12 个任务 × 12.5 分）。
struct ModelIQEntry: Identifiable {
    var id: String { "\(name)/\(tag)" }
    let name: String        // 例 "gpt-5.5"（来自 JSON 的 model）
    let tag: String         // 推理强度：low / medium / high / xhigh（来自 reasoning_effort）
    let score: Double       // 智商分
    let passed: Int
    let tasks: Int
    let status: HealthStatus

    /// "10/12"
    var passLabel: String { "\(passed)/\(tasks)" }

    /// 整数分去掉 .0（125），非整数保留（87.5）。
    var scoreLabel: String {
        score == score.rounded() ? String(Int(score)) : String(score)
    }

    /// 评分条填充比例 0...1，满分 150。
    var barFraction: Double { min(max(score / 150.0, 0), 1) }
}

/// 一次拉取后的视图快照。
struct RadarSnapshot {
    let models: [ModelIQEntry]    // 已按规则排序
    let updatedAt: Date           // quota_radar.updated_at 的真实时刻（用于实时相对时间）
    let reset24hPercent: Double   // 0...100

    var updatedAtLocal: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: updatedAt)
    }

    var reset24hLabel: String { "\(Int(reset24hPercent.rounded()))%" }

    /// 仅高概率绿色高亮；低概率走普通中性显示。满分 100%。
    var highlightReset: Bool { reset24hPercent >= 70 }
}
