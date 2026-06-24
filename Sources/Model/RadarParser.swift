// 拼装 + 字段映射 + 排序 + 时间解析 + 相对时间。
import Foundation

enum RadarParser {

    /// 推理强度排序权重：low < medium < high < xhigh。
    static let effortRank: [String: Int] = ["low": 0, "medium": 1, "high": 2, "xhigh": 3]

    /// 从模型名解析底座版本号，"gpt-5.5" -> 5.5。
    static func versionNumber(_ name: String) -> Double {
        Double(name.filter { $0.isNumber || $0 == "." }) ?? 0
    }

    static func parse(_ data: Data) throws -> RadarSnapshot {
        let resp = try JSONDecoder().decode(CurrentResponse.self, from: data)

        // 1) 拼装评分列表：latest（主条目）+ 所有 comparisons 的 latest。
        let runs: [Run] = (resp.modelIQ.latest.map { [$0] } ?? [])
            + resp.modelIQ.comparisons.values.compactMap { $0.latest }

        // 2) 映射 + 排序：智商降序 → 同分先比底座版本（新者优先）→ 再比思考档（低档优先）。
        let entries = runs.map { run in
            ModelIQEntry(
                name: run.model,
                tag: run.reasoningEffort,
                score: run.score,
                passed: run.passed,
                tasks: run.tasks,
                status: HealthStatus(rawValue: run.status) ?? .red
            )
        }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }      // 智商降序
            let va = versionNumber(a.name), vb = versionNumber(b.name)
            if va != vb { return va > vb }                          // 新底座优先
            return (effortRank[a.tag] ?? 0) < (effortRank[b.tag] ?? 0) // 低思考档优先
        }

        // 3) 更新时间：quota_radar.updated_at(UTC ISO) -> Date；展示层按用户当前时区格式化。
        let iso = resp.modelIQ.quotaRadar.updatedAt
        let date = parseISO(iso)

        // 4) 24h 重置概率（prediction.probability_24h），归一到 0...100。
        let raw24 = resp.prediction.probability24h ?? 0
        let pct = raw24 <= 1.0 ? raw24 * 100 : raw24

        return RadarSnapshot(
            models: entries,
            updatedAt: date ?? Date(),
            reset24hPercent: pct
        )
    }

    /// 解析 ISO8601（兼容带/不带小数秒）。
    static func parseISO(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    /// 实时相对时间："X 小时 X 分钟" / "X 分钟"。
    static func relativeLabel(from updatedAt: Date, to now: Date = Date()) -> String {
        let mins = max(0, Int((now.timeIntervalSince(updatedAt) / 60).rounded(.down)))
        let h = mins / 60, m = mins % 60
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(m) 分钟"
    }
}
