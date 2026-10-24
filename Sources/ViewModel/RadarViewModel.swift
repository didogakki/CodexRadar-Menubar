// 弹窗状态：快照 / 加载态 / 错误 / 实时相对时间。
import Foundation
import Combine

@MainActor
final class RadarViewModel: ObservableObject {
    @Published private(set) var snapshot: RadarSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var relativeLabel = "—"
    /// 榜单筛选：nil = 全部分区；否则只展示选中的那一个（见 BoardSection.displayOrder）。
    @Published var boardFilter: BoardSection? = nil
    /// 只看性价比前沿：隐藏被组内其他档位压制的行（推荐项/菜单栏档位豁免，见 GroupSectionView）。
    /// 跨会话记忆用户选择，弹窗每次重开都保持。
    @Published var onlyFrontier: Bool = UserDefaults.standard.bool(forKey: RadarViewModel.onlyFrontierKey) {
        didSet { UserDefaults.standard.set(onlyFrontier, forKey: RadarViewModel.onlyFrontierKey) }
    }

    static let onlyFrontierKey = "onlyFrontier"

    /// 榜单展示模式：模型推荐（默认）/ 完整榜单。跨会话记忆，弹窗每次重开都保持；
    /// 刷新（refresh()）只替换 snapshot，不touch这个字段，切换模式不会被下一次轮询重置。
    @Published var listMode: ModelListMode = ModelListMode(
        rawValue: UserDefaults.standard.string(forKey: RadarViewModel.listModeKey) ?? ""
    ) ?? .recommendation {
        didSet { UserDefaults.standard.set(listMode.rawValue, forKey: RadarViewModel.listModeKey) }
    }

    static let listModeKey = "listMode"

    /// 「模型推荐」折叠行的展开状态（key = ModelRecommendationGroup.id）。只存于内存，
    /// 不随 refresh() 或模式切换重置；不需要跨会话记忆，用户重开弹窗默认全部折叠即可。
    @Published var expandedRecommendationIDs: Set<String> = []

    func toggleRecommendationExpanded(_ id: String) {
        if expandedRecommendationIDs.contains(id) {
            expandedRecommendationIDs.remove(id)
        } else {
            expandedRecommendationIDs.insert(id)
        }
    }

    /// 刷新来源：启动 / 后台轮询只补读缺失或过期（≥ staleAfter）的档位，避免每次轮询扫全部请求；
    /// 手动刷新重读全部档位（单档距上次成功读取不足 manualMinInterval 的除外）。
    enum RefreshTrigger {
        case launch
        case background
        case manual
    }

    /// 读取进度（"读取中 12/34"），仅刷新期间非 nil。
    @Published private(set) var progressLabel: String?

    private let service: RadarService
    private let store: RadarBenchStore
    private let clock: () -> Date
    private var relativeTimer: Timer?
    private var refreshToken: UInt = 0
    private var inFlight: Task<Void, Never>?

    // Radar Bench 读取状态：绑定 + 每档最近一次成功观测。snapshot 始终由它们重新组装，
    // 因此失败的读取不会替换已有的成功行，换基准时旧观测整体丢弃。
    private var binding: RadarBenchBinding?
    private var entries: [String: RadarBenchEntry] = [:]
    private var cooldownUntil: Date?
    private var lastBuildAt: Date
    private var batchDone = 0

    /// - Parameters:
    ///   - cacheDefaults: 观测缓存所在的 UserDefaults（偏好 onlyFrontier / listMode 始终存 `.standard`）。
    init(
        service: RadarService = RadarService(),
        cacheDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.store = RadarBenchStore(defaults: cacheDefaults)
        self.clock = now
        self.lastBuildAt = now()
        // 先用 24h 内、通过当前校验的缓存立即出榜单（行上标注成功读取时间），随后后台刷新。
        if let cached = store.load(now: now()) {
            binding = cached.binding
            entries = cached.entries
            publish()
        }
        // "距今" 每分钟刷新一次，保证相对时间实时走动；同时让跨过「沿用缓存 / 24h 作废」阈值的行及时更新。
        relativeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit {
        relativeTimer?.invalidate()
    }

    func refresh(trigger: RefreshTrigger = .manual) async {
        if let running = inFlight {
            // 后台/启动触发遇到进行中的刷新：并入它，不重复发起；手动刷新则取代旧的一轮。
            if trigger != .manual { await running.value; return }
            running.cancel()
        }
        refreshToken &+= 1
        let token = refreshToken
        let task = Task { await self.performRefresh(trigger: trigger, token: token) }
        inFlight = task
        await task.value
        if refreshToken == token { inFlight = nil }
    }

    private func performRefresh(trigger: RefreshTrigger, token: UInt) async {
        let startedAt = clock()
        if let until = cooldownUntil, until > startedAt {
            lastError = "站点繁忙，请约 \(Int(until.timeIntervalSince(startedAt).rounded(.up))) 秒后再刷新"
            return
        }
        isLoading = true
        defer {
            if refreshToken == token {
                isLoading = false
                progressLabel = nil
            }
        }

        // 1. 绑定：身份校验失败或读不到时不读成绩（无法确认基准仍是同一个），沿用 24h 内的缓存榜单。
        let fresh: RadarBenchBinding
        do {
            fresh = try await service.fetchBinding()
        } catch is CancellationError {
            return
        } catch {
            guard refreshToken == token else { return }
            if case RadarServiceError.busy(_, let retryAfter?) = error {
                cooldownUntil = clock().addingTimeInterval(retryAfter)
            }
            let reason = Self.describe(error)
            lastError = snapshot == nil ? reason : "绑定读取失败（\(reason)），仍展示上次结果"
            return
        }
        guard refreshToken == token else { return }
        applyBinding(fresh)

        // 2. 本轮要读取的档位。
        let targets = selectionsToFetch(trigger: trigger, binding: fresh, now: clock())
        guard !targets.isEmpty else {
            lastError = failureNotice(stopReason: nil)
            store.save(binding: fresh, entries: entries)
            return
        }
        batchDone = 0
        progressLabel = "读取中 0/\(targets.count)"
        let total = targets.count

        let outcome = await service.fetchBatch(binding: fresh, selections: targets) { [weak self] selection, result in
            guard let self, self.refreshToken == token else { return }
            self.apply(result, to: selection, at: self.clock())
            self.batchDone += 1
            self.progressLabel = "读取中 \(self.batchDone)/\(total)"
        }
        guard refreshToken == token else { return }

        if let retryAfter = outcome.retryAfter {
            cooldownUntil = clock().addingTimeInterval(retryAfter)
        } else if outcome.stopReason != nil {
            cooldownUntil = clock().addingTimeInterval(300)
        }
        store.save(binding: fresh, entries: entries)
        lastError = failureNotice(stopReason: outcome.stopReason)
    }

    /// 绑定变化处理：基准身份（benchmark / catalog / task_set_sha256 / 计分版本 / 满分 / 任务数）任一不同，
    /// 已有观测与缓存整体作废，不跨基准混用；同一基准下只剔除已不在绑定里的档位。
    private func applyBinding(_ fresh: RadarBenchBinding) {
        if let old = binding, !old.isSameBenchmark(as: fresh) {
            entries = [:]
            store.clear()
        } else {
            let known = Set(fresh.selections.map(\.id))
            entries = entries.filter { known.contains($0.key) }
        }
        binding = fresh
        publish()
    }

    private func selectionsToFetch(trigger: RefreshTrigger, binding: RadarBenchBinding, now: Date) -> [BenchSelection] {
        binding.selections.filter { selection in
            guard let entry = entries[selection.id], entry.observation != nil, let fetchedAt = entry.fetchedAt else {
                return true
            }
            if entry.lastError != nil { return true }
            let age = now.timeIntervalSince(fetchedAt)
            switch trigger {
            case .manual: return age >= RadarBenchPolicy.manualMinInterval || age < 0
            case .launch, .background: return age >= RadarBenchPolicy.staleAfter || age < 0
            }
        }
    }

    private func apply(_ result: Result<RadarBenchObservation, Error>, to selection: BenchSelection, at now: Date) {
        switch result {
        case .success(let observation):
            entries[selection.id] = RadarBenchEntry(observation: observation, fetchedAt: now, lastError: nil)
        case .failure(let error):
            // 失败只记录原因：已有的成功观测与它的读取时间原样保留。
            var entry = entries[selection.id] ?? RadarBenchEntry()
            entry.lastError = Self.describe(error)
            entries[selection.id] = entry
        }
        publish()
    }

    /// 用当前绑定 + 逐档状态重新组装快照；没有任何有效观测时为 nil（不拿占位数据充数）。
    private func publish() {
        let now = clock()
        lastBuildAt = now
        if let binding {
            snapshot = RadarBenchParser.makeSnapshot(binding: binding, entries: entries, now: now)
        } else {
            snapshot = nil
        }
        if let snapshot {
            boardFilter = Self.reconciledFilter(boardFilter, in: snapshot)
        }
        updateRelative()
    }

    private func tick() {
        updateRelative()
        guard binding != nil else { return }
        let now = clock()
        let crossed = entries.values.contains { entry in
            guard entry.observation != nil, let fetchedAt = entry.fetchedAt else { return false }
            let before = lastBuildAt.timeIntervalSince(fetchedAt)
            let after = now.timeIntervalSince(fetchedAt)
            return [RadarBenchPolicy.staleAfter, RadarBenchPolicy.maxCacheAge].contains { before <= $0 && after > $0 }
        }
        if crossed { publish() }
    }

    /// 头部提示：本轮暂停原因 + 最近一次读取失败的档位数。无问题返回 nil。
    private func failureNotice(stopReason: String?) -> String? {
        guard let binding else { return stopReason }
        let failed = binding.selections.filter { entries[$0.id]?.lastError != nil }
        var parts: [String] = []
        if let stopReason { parts.append(stopReason) }
        if !failed.isEmpty {
            let kept = failed.filter { entries[$0.id]?.observation != nil }.count
            var text = "\(failed.count) 个档位读取失败"
            if kept > 0 { text += "（\(kept) 个沿用上次结果）" }
            if snapshot == nil, let reason = entries[failed[0].id]?.lastError { text += "：\(reason)" }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func updateRelative() {
        guard let snap = snapshot else { relativeLabel = "—"; return }
        relativeLabel = RadarParser.relativeLabel(from: snap.updatedAt, to: clock())
    }

    /// 旧数据源口径下保留上一次好快照时的头部提示文案（Radar Bench 改为逐档合并，见 apply(_:to:at:)）。
    static let staleNotice = "数据源暂时不可用，仍展示上次结果"

    /// （旧数据源口径）新快照的数据来源比现有快照更不完整时不予覆盖（例如权威指标源挂掉、只剩两三条推荐条目），
    /// 避免一次瞬时故障就把已经拿到的完整榜单换成残缺列表。提取为纯函数便于独立测试。
    nonisolated static func shouldReplace(_ current: RadarSnapshot?, with new: RadarSnapshot) -> Bool {
        guard let current else { return true }
        return new.codexSource >= current.codexSource
    }

    /// 若当前选中的分区在新快照中已经没有内容，回退为「全部」；否则保留用户选择。
    /// 提取为纯函数便于独立测试，不依赖网络请求。
    nonisolated static func reconciledFilter(_ filter: BoardSection?, in snapshot: RadarSnapshot) -> BoardSection? {
        guard let filter else { return nil }
        return snapshot.availableSections.contains(filter) ? filter : nil
    }
}

#if DEBUG
extension RadarViewModel {
    /// 仅用于 SwiftUI 预览 / 离线渲染校验：构造固定 UI 状态。
    static func preview(
        _ snapshot: RadarSnapshot? = nil,
        isLoading: Bool = false,
        lastError: String? = nil
    ) -> RadarViewModel {
        let vm = RadarViewModel()
        vm.snapshot = snapshot
        vm.isLoading = isLoading
        vm.lastError = lastError
        if let snapshot {
            vm.relativeLabel = RadarParser.relativeLabel(from: snapshot.updatedAt)
        }
        return vm
    }
}
#endif
