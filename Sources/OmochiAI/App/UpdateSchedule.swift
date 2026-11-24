import AppKit

/// アップデートの自動確認の間隔。既定は「確認しない」（選んだ人だけ、GitHub の公開 API で最新リリースの版を読む）
enum UpdateCheckInterval: String, Codable, CaseIterable {
    case never, daily, weekly, monthly

    var label: String {
        switch self {
        case .never: return L("確認しない")
        case .daily: return L("毎日")
        case .weekly: return L("毎週")
        case .monthly: return L("毎月")
        }
    }

    /// 間隔（秒）。確認しないときは nil
    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .daily: return 86_400
        case .weekly: return 7 * 86_400
        case .monthly: return 30 * 86_400
        }
    }

    /// 前に確かめた時刻（UNIX 秒。0 = まだ）から見て、いま確かめる番か
    func isDue(lastCheck: Double, now: Date = Date()) -> Bool {
        guard let s = seconds else { return false }
        guard lastCheck > 0 else { return true }
        let elapsed = now.timeIntervalSince1970 - lastCheck
        // 時計が戻って前の確認が「未来」になったときも確かめ直す
        return elapsed >= s || elapsed < 0
    }
}

/// アップデートの自動確認。1 時間ごとに「確かめる番か」を見て、番のときだけ最新リリースの版を読む（入れ替えはしない）。
/// 新しい版があれば、おもちの吹き出しとメニューで知らせる（入力先は奪わない）。入れ替えるのは、ユーザーが「アップデートする」を押したときだけ
final class UpdateSchedule {
    static let shared = UpdateSchedule()
    private weak var manager: JellyManager?
    private var timer: Timer?
    private var checking = false
    /// 見つけた新しい版のタグ（メニューの「アップデートを確認…」を「新しい版 … があります…」にする）
    private(set) var available: String?

    func start(manager: JellyManager) {
        self.manager = manager
        timer?.invalidate()
        // 起動した直後の作業の邪魔をしないよう、最初は 1 分後に
        let first = Timer(timeInterval: 60, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(first, forMode: .common)
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// メニューで間隔を変えたとき：確かめる番なら、すぐ確かめる
    func intervalChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard let m = manager, !checking else { return }
        let s = m.settings
        guard s.updateCheck.isDue(lastCheck: s.lastUpdateCheck) else { return }
        checking = true
        UpdateChecker.fetchLatest { [weak self] latest in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                guard let tag = latest.tag, latest.status == 200 else {
                    // 読めなかったときは次の 1 時間後にもう一度（前に確かめた時刻は変えない）
                    AppLog.write("update auto-check failed: \(latest.status) \(latest.error?.localizedDescription ?? "")")
                    return
                }
                m.updateSettings { $0.lastUpdateCheck = Date().timeIntervalSince1970 }
                AppLog.write("update auto-check (\(s.updateCheck.rawValue)): latest \(tag)")
                if self.note(latest: tag), tag != m.settings.skippedUpdateVersion {
                    m.showUpdateBubble(tag)
                }
            }
        }
    }

    /// 最新の版を覚える（手で確かめたときも）。いまより新しければ true
    @discardableResult
    func note(latest tag: String) -> Bool {
        let newer = AppVersion.isNewer(tag, than: AppInfo.version)
        available = newer ? tag : nil
        return newer
    }
}
