// 弹窗状态：快照 / 加载态 / 错误 / 实时相对时间。
import Foundation
import Combine

@MainActor
final class RadarViewModel: ObservableObject {
    @Published private(set) var snapshot: RadarSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var relativeLabel = "—"

    private let service = RadarService()
    private var relativeTimer: Timer?

    init() {
        // "距今" 每 30 秒刷新一次，保证相对时间实时走动。
        relativeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRelative() }
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await service.fetch()
            snapshot = snap
            lastError = nil
            updateRelative()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func updateRelative() {
        guard let snap = snapshot else { relativeLabel = "—"; return }
        relativeLabel = RadarParser.relativeLabel(from: snap.updatedAt)
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
