// 视图层使用的领域模型（已与解码层解耦）。
// 综合分 = (iq/maxIq)^0.42 · (min(passed,8)/8)^0.13 · (minCost/cost)^0.30 · (minTime/time)^0.15，所有候选都展示。
import Foundation

/// Claude 参考数据（来自 HTML best-effort）的可用状态。
enum ClaudeStatus {
    case ok
    case unavailable
}

/// 模型族 —— 决定分组归属。
enum ModelFamily {
    case codex
    case claude

    /// 组标题（正常大小写）。
    var title: String {
        switch self {
        case .codex:  return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

/// 单条候选模型的原始记录（来自 HTML 对比表）。
struct ModelResult {
    let name: String        // "gpt-5.5" / "opus-4.8"
    let depth: String       // 思考档：medium / high / xhigh / max
    let iq: Double          // 智力基准分（外部 intelligence index，质量主轴）
    let passed: Int         // 通过任务数
    let tasks: Int          // 任务总数（展示用，与综合分归一脱钩）
    let cost: Double        // 美元成本（越低越好）
    let timeMinutes: Int    // 耗时（分钟，越低越好）
    let family: ModelFamily
    let isReference: Bool   // 来自 HTML 单日参考快照（Opus 列）
}

/// 带综合分的模型（综合分由 RadarParser 计算）。
struct ScoredModel: Identifiable {
    let result: ModelResult
    let score: Double

    var id: String { "\(result.name)/\(result.depth)" }

    // 展示派生 —————————————————————————————————————————————

    /// 综合分保留两位小数："0.93"。
    var scoreLabel: String { String(format: "%.2f", score) }

    /// 进度条填充比例 0...1。
    var barFraction: Double { min(max(score, 0), 1) }

    /// 智力基准分（透传 result）。
    var iq: Double { result.iq }

    /// IQ 数值文本（一位小数）："87.5"。
    var iqLabel: String { String(format: "%.1f", result.iq) }

    /// "7/12"。
    var passLabel: String { "\(result.passed)/\(result.tasks)" }

    /// "$23.9"（保留一位小数）。
    var costLabel: String { String(format: "$%.1f", result.cost) }

    /// "1h25m" / "28m"。
    var timeLabel: String {
        let h = result.timeMinutes / 60
        let m = result.timeMinutes % 60
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 菜单栏紧凑名："5.5·medium"（去掉 gpt- 前缀）。
    var compactName: String {
        let base = result.name.replacingOccurrences(of: "gpt-", with: "")
        return "\(base)·\(result.depth)"
    }
}

/// 一次拉取后的视图快照。
struct RadarSnapshot {
    let all: [ScoredModel]   // 全部候选，综合分降序（仅组内可比）
    let updatedAt: Date      // quota_radar.updated_at 的真实时刻（用于实时相对时间）
    var claudeStatus: ClaudeStatus = .ok   // Claude 参考列是否抓取成功

    /// Codex 组（按综合分降序，索引即组内名次）。
    var codexGroup: [ScoredModel] { all.filter { $0.result.family == .codex } }

    /// Claude Code 组（按综合分降序，索引即组内名次）。
    var claudeGroup: [ScoredModel] { all.filter { $0.result.family == .claude } }

    /// 菜单栏跟随的模型：综合分最高的 Codex 族（业务规则：菜单栏只跟 Codex 冠军）。
    var menuBarBest: ScoredModel? { all.first { $0.result.family == .codex } }

    /// 绝对检测时间戳："2026-06-25 14:28"（本地时区）。
    var checkedAtLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: updatedAt)
    }
}
