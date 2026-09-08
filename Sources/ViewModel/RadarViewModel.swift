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

    private let service = RadarService()
    private var relativeTimer: Timer?
    private var refreshToken: UInt = 0

    init() {
        // "距今" 每分钟刷新一次，保证相对时间实时走动。
        relativeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRelative() }
        }
    }

    deinit {
        relativeTimer?.invalidate()
    }

    func refresh() async {
        refreshToken &+= 1
        let token = refreshToken
        isLoading = true
        do {
            let snap = try await service.fetch()
            guard refreshToken == token else { return }
            guard Self.shouldReplace(snapshot, with: snap) else {
                // 上游权威源暂时不可用，这次只拿到更不完整的结果：保留上一次的好快照，仅提示。
                lastError = Self.staleNotice
                isLoading = false
                return
            }
            snapshot = snap
            boardFilter = Self.reconciledFilter(boardFilter, in: snap)
            lastError = nil
            updateRelative()
            isLoading = false
        } catch {
            guard refreshToken == token else { return }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }

    private func updateRelative() {
        guard let snap = snapshot else { relativeLabel = "—"; return }
        relativeLabel = RadarParser.relativeLabel(from: snap.updatedAt)
    }

    /// 保留上一次好快照时的头部提示文案。
    static let staleNotice = "数据源暂时不可用，仍展示上次结果"

    /// 新快照的数据来源比现有快照更不完整时不予覆盖（例如权威指标源挂掉、只剩两三条推荐条目），
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
