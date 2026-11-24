import Foundation

/// チャットの「予約」の 1 行：いまの作業が終わったら送る指示。
/// 送るまでは文・送り先・前の結果を渡すかを自由に変えられる
struct QueuedPrompt: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 本人が打った指示
    var text: String
    /// 送り先のおもち（nil = この予約を作ったおもち）
    var target: UUID?
    /// 前の手順の結果を指示に添えて渡す
    var passResult: Bool = false
    /// 予約したときに付けた添付・画面の欄（OMOCHI AI が付ける部分。送るときに指示の後ろに付ける）
    var suffix: String?
    /// 添付の数（表示用）
    var attachmentCount: Int = 0
}

/// 予約が止まっている理由
enum QueuePause: Codable, Equatable {
    /// 本人が ⏸ を押した
    case manual
    /// 前の作業を止めた（■）
    case stopped
    /// 前の作業がエラーで終わった
    case failed(String?)
    /// 送ろうとしたおもちが動かせなかった（ログインしていないなど）
    case refused(String?)
    /// 送り先のおもちが消えた
    case targetMissing
    /// アプリを終了した（終了で作業が中断されるので、勝手に続きを送らない）
    case restarted
}

/// 前の手順の結果（次の手順に渡す）
struct QueueStepResult: Codable, Equatable {
    var agent: UUID
    var name: String
    var text: String
}

/// おもち 1 体ぶんの予約（この予約を作ったおもち = owner）
struct PromptQueue: Codable, Equatable {
    let owner: UUID
    var items: [QueuedPrompt] = []
    var pause: QueuePause?
    /// いま結果を待っているおもち（その作業が終わったら次の行を送る）
    var watching: UUID?
    /// 直前の手順の結果
    var lastResult: QueueStepResult?
    /// これまでに送った数（「2 件目」などの表示用。予約が空になったら 0 に戻す）
    var sent = 0
    /// 次に止まった作業は一時停止にせず、次の行へ進む（「止めて次へ」）
    var skipNextStop = false

    var isPaused: Bool { pause != nil }
    /// 予約が進んでいる（前の作業の終わりを待っている・次の行を送ろうとしている）
    var isActive: Bool { !isPaused && (watching != nil || !items.isEmpty) }
}

enum QueueSubmitResult: Equatable {
    case sent
    /// 送れなかった（ログインしていない・作業中など。理由）
    case refused(String?)
}

/// 予約を動かすのに必要な、おもちとのやりとり（アプリでは JellyManager、テストでは偽物）
protocol PromptQueueHost: AnyObject {
    func queueAgentExists(_ id: UUID) -> Bool
    func queueAgentRunning(_ id: UUID) -> Bool
    func queueAgentName(_ id: UUID) -> String
    /// 指示を送る
    func queueSubmit(_ prompt: String, to id: UUID) -> QueueSubmitResult
    func queueCancel(_ id: UUID)
    /// 予約が変わった（表示を更新する）。agents = 予約の持ち主と、送り先として関わるおもち
    func queuesChanged(_ agents: Set<UUID>)
    /// 前の手順の結果を、別のおもちへ渡した（見た目：塊が渡っていく）
    func queueHandoff(from: UUID, to: UUID)
}

extension PromptQueueHost {
    func queueHandoff(from: UUID, to: UUID) {}
}

/// すべてのおもちの予約を動かす。
/// 予約の行は、前の作業（その予約のおもちの作業、または前の行を送ったおもちの作業）が「完了」したら順に送る。
/// 送り先が作業中なら手が空くまで待つ。エラー・中止で終わったら一時停止し、本人が ▶ で再開する
final class PromptQueues {
    /// 次の手順に渡す結果の長さの上限（文字）
    static let resultLimit = 20_000
    /// 予約の行を書き換えている途中なら、最後に打ってからこの秒数は送らずに待つ
    static let editHold: TimeInterval = 4

    weak var host: PromptQueueHost?
    private(set) var queues: [UUID: PromptQueue] = [:]
    private let file: URL?
    /// 行ごとの最後に書き換えた時刻
    private var editedAt: [UUID: Date] = [:]
    private var repumpScheduled = false
    /// テスト用：いまの時刻
    var now: () -> Date = Date.init
    /// テスト用：少し後で動かす（既定はメインスレッドで）
    var later: (TimeInterval, @escaping () -> Void) -> Void = { d, f in DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }

    init(file: URL?) {
        self.file = file
        load()
    }

    func queue(_ owner: UUID) -> PromptQueue? { queues[owner] }
    func items(_ owner: UUID) -> [QueuedPrompt] { queues[owner]?.items ?? [] }
    func isActive(_ owner: UUID) -> Bool { queues[owner]?.isActive ?? false }

    // MARK: - 予約を足す・変える

    /// 予約に足す。owner が作業中で、まだ何も待っていなければ、その作業の終わりを待つ
    @discardableResult
    func enqueue(owner: UUID, text: String, target: UUID? = nil, passResult: Bool? = nil, suffix: String? = nil, attachments: Int = 0) -> QueuedPrompt? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var q = queues[owner] ?? PromptQueue(owner: owner)
        let to = target == owner ? nil : target
        // 別のおもちに送るときは、既定で前の結果を渡す（同じおもちなら会話が続いているので要らない）
        let item = QueuedPrompt(text: t, target: to, passResult: passResult ?? (to != nil), suffix: suffix, attachmentCount: attachments)
        if q.items.isEmpty && q.watching == nil && !q.isPaused {
            q.sent = 0
            q.lastResult = nil
            if host?.queueAgentRunning(owner) == true { q.watching = owner }
        }
        q.items.append(item)
        queues[owner] = q
        AppLog.write("queue \(owner.uuidString.prefix(8)): add \(item.id.uuidString.prefix(6)) (\(q.items.count) waiting\(q.watching != nil ? ", after the running task" : ""))")
        changed(owner)
        pump()
        return item
    }

    func update(owner: UUID, item id: UUID, text: String? = nil, target: UUID?? = nil, passResult: Bool? = nil) {
        guard var q = queues[owner], let i = q.items.firstIndex(where: { $0.id == id }) else { return }
        if let text {
            q.items[i].text = text
            editedAt[id] = now()
        }
        if let target {
            let t = target == owner ? nil : target
            // 送り先を変えたら、渡すかどうかも合わせる（別のおもちへは渡す、自分へは渡さない）
            if t != q.items[i].target && passResult == nil { q.items[i].passResult = t != nil }
            q.items[i].target = t
        }
        if let passResult { q.items[i].passResult = passResult }
        queues[owner] = q
        // 文の書き換えでは保存だけ（表示は書いている欄そのもの）。送り先などは表示も更新
        if text == nil || target != nil || passResult != nil { changed(owner) } else { save() }
        if text == nil { pump() }
    }

    /// 書き換え終わった（欄から出た）：待たずに送ってよい
    func endEditing(owner: UUID, item id: UUID) {
        editedAt[id] = nil
        changed(owner)
        pump()
    }

    func remove(owner: UUID, item id: UUID) {
        guard var q = queues[owner] else { return }
        q.items.removeAll { $0.id == id }
        editedAt[id] = nil
        queues[owner] = q
        settle(owner)
        changed(owner)
    }

    /// 並べ替え（by = -1 で上へ、+1 で下へ）
    func move(owner: UUID, item id: UUID, by: Int) {
        guard var q = queues[owner], let i = q.items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + by
        guard j >= 0, j < q.items.count else { return }
        q.items.swapAt(i, j)
        queues[owner] = q
        changed(owner)
    }

    func clear(owner: UUID) {
        guard var q = queues[owner] else { return }
        for it in q.items { editedAt[it.id] = nil }
        q.items = []
        queues[owner] = q
        settle(owner)
        changed(owner)
    }

    func pause(owner: UUID) {
        guard var q = queues[owner], !q.items.isEmpty || q.watching != nil else { return }
        q.pause = .manual
        queues[owner] = q
        AppLog.write("queue \(owner.uuidString.prefix(8)): paused (manual)")
        changed(owner)
    }

    /// 再開する。いまそのおもちが作業中なら、その作業の終わりを待ってから次の行を送る
    func resume(owner: UUID) {
        guard var q = queues[owner], q.isPaused else { return }
        q.pause = nil
        q.skipNextStop = false
        if q.watching == nil, host?.queueAgentRunning(owner) == true { q.watching = owner }
        queues[owner] = q
        AppLog.write("queue \(owner.uuidString.prefix(8)): resumed")
        changed(owner)
        pump()
    }

    /// 「止めて次へ」：いま待っている作業を止めて、一時停止せずに次の行へ進む
    func skipCurrent(owner: UUID) {
        guard var q = queues[owner], let w = q.watching, host?.queueAgentRunning(w) == true else { return }
        q.skipNextStop = true
        q.pause = nil
        queues[owner] = q
        AppLog.write("queue \(owner.uuidString.prefix(8)): skip current")
        host?.queueCancel(w)
        changed(owner)
    }

    /// 予約しているおもち・送り先として待たれているおもちが消えた
    func agentRemoved(_ id: UUID) {
        if let q = queues.removeValue(forKey: id) { for it in q.items { editedAt[it.id] = nil } }
        for (o, var q) in queues where q.watching == id {
            q.watching = nil
            q.pause = q.items.isEmpty ? nil : .targetMissing
            queues[o] = q
            changed(o)
        }
        save()
        pump()
    }

    // MARK: - 作業の終わり → 次の行

    /// おもちの作業が終わった（state はそのターンの終わり方）
    func turnEnded(agent: UUID, state: AgentState, result: String?) {
        for (o, var q) in queues where q.watching == agent {
            q.watching = nil
            switch state {
            case .completed:
                q.lastResult = QueueStepResult(agent: agent, name: host?.queueAgentName(agent) ?? "", text: result ?? "")
                q.skipNextStop = false
            case .cancelled where q.skipNextStop:
                q.lastResult = nil
                q.skipNextStop = false
            default:
                q.lastResult = nil
                q.skipNextStop = false
                if !q.items.isEmpty { q.pause = state == .cancelled ? .stopped : .failed(result) }
            }
            if q.items.isEmpty { q.sent = 0 }
            queues[o] = q
            AppLog.write("queue \(o.uuidString.prefix(8)): step on \(agent.uuidString.prefix(8)) ended \(state.rawValue) (\(q.items.count) waiting\(q.isPaused ? ", paused" : ""))")
            changed(o)
        }
        pump()
    }

    /// 送れる行を送る（送り先の手が空いていて、止まっていない予約の先頭）
    func pump() {
        guard let host else { return }
        var holdUntil: Date?
        // 古い予約から（予約を作った順を保つため、持ち主の ID ではなく最初の行で並べる必要はない：
        // 送り先が同じなら、先に作業が終わったほうが先に取る）
        for o in queues.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var q = queues[o], !q.isPaused, q.watching == nil else { continue }
            // 文を消して空にした行は送らずに捨てる
            while let f = q.items.first, f.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, editedAt[f.id] == nil {
                q.items.removeFirst()
                queues[o] = q
            }
            guard let item = q.items.first else { continue }
            let target = item.target ?? o
            guard host.queueAgentExists(target) else {
                q.pause = .targetMissing
                queues[o] = q
                changed(o)
                continue
            }
            if host.queueAgentRunning(target) { continue }
            // 書き換えている途中の行は、打ち終わるまで少し待つ
            if let t = editedAt[item.id], now().timeIntervalSince(t) < PromptQueues.editHold {
                let until = t.addingTimeInterval(PromptQueues.editHold)
                holdUntil = min(holdUntil ?? until, until)
                continue
            }
            q.items.removeFirst()
            editedAt[item.id] = nil
            let prompt = PromptQueues.prompt(for: item, previous: q.lastResult, owner: o)
            // 送る前に「待っている」にしておく（起動に失敗すると、送ったその場で作業の終わりが届くため）
            q.watching = target
            q.sent += 1
            queues[o] = q
            AppLog.write("queue \(o.uuidString.prefix(8)): send \(item.id.uuidString.prefix(6)) to \(target.uuidString.prefix(8)) pass=\(item.passResult && q.lastResult != nil)")
            let handoffFrom = item.passResult ? q.lastResult?.agent : nil
            if case .refused(let why) = host.queueSubmit(prompt, to: target) {
                // 送れなかった：行を戻して止める
                var back = queues[o] ?? q
                back.watching = nil
                back.sent = max(0, back.sent - 1)
                back.items.insert(item, at: 0)
                back.pause = .refused(why)
                queues[o] = back
                AppLog.write("queue \(o.uuidString.prefix(8)): refused (\(why ?? "-"))")
            } else if let f = handoffFrom, f != target {
                host.queueHandoff(from: f, to: target)
            }
            changed(o, also: [target])
        }
        if let until = holdUntil, !repumpScheduled {
            repumpScheduled = true
            later(max(0.05, until.timeIntervalSince(now()) + 0.05)) { [weak self] in
                self?.repumpScheduled = false
                self?.pump()
            }
        }
    }

    // MARK: - 指示の文

    /// 前の手順の結果を渡すときの目印（指示の中で、本人が打った部分と分けるため。訳さない）
    static let resultMarker = "\n\n---\n[前の手順の結果]"

    /// 送る指示：本人が打った文 ＋（渡すなら）前の手順の結果 ＋ 予約したときの添付・画面の欄
    static func prompt(for item: QueuedPrompt, previous: QueueStepResult?, owner: UUID) -> String {
        var p = item.text
        if item.passResult, let r = previous, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var body = r.text
            if body.count > resultLimit { body = String(body.prefix(resultLimit)) + "\n" + L("…（長いので省略。続きは %@ の会話にあります）", r.name) }
            p += resultMarker + " " + r.name + "\n" + defang(body)
        }
        if let s = item.suffix { p += s }
        return p
    }

    /// 結果の中に OMOCHI AI の目印（添付・画面・前の結果の欄）と同じ形があっても、目印として読まれないようにする
    static func defang(_ s: String) -> String {
        s.replacingOccurrences(of: "\n---\n[", with: "\n--- \n[")
    }

    /// 指示の中の「前の手順の結果」の欄：渡したおもちの名前（なければ nil）
    static func passedFrom(_ prompt: String) -> String? {
        guard let r = prompt.range(of: resultMarker) else { return nil }
        let rest = prompt[r.upperBound...]
        let line = rest.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return line
    }

    // MARK: - 表示

    /// 予約の状態の 1 行（チャットの予約の欄の見出し）
    func statusLine(_ owner: UUID) -> String? {
        guard let q = queues[owner], !q.items.isEmpty || q.watching != nil else { return nil }
        if let p = q.pause { return PromptQueues.pauseText(p) }
        if let w = q.watching {
            if w == owner && q.sent == 0 { return L("いまの作業が終わったら、上から順に送ります") }
            let who = w == owner ? L("このおもち") : (host?.queueAgentName(w) ?? "?")
            return L("%@ が %ld 件目を作業中。終わったら次を送ります", who, q.sent)
        }
        if let first = q.items.first {
            let t = first.target ?? owner
            if host?.queueAgentRunning(t) == true {
                return L("%@ の手が空くのを待っています", t == owner ? L("このおもち") : (host?.queueAgentName(t) ?? "?"))
            }
            if editedAt[first.id] != nil { return L("書き換えが終わったら送ります") }
        }
        return nil
    }

    static func pauseText(_ p: QueuePause) -> String {
        switch p {
        case .manual: return L("⏸ 一時停止中（▶ で続きを送ります）")
        case .stopped: return L("⏸ 作業を止めたので、予約も止めています（▶ で続きを送ります）")
        case .failed: return L("⏸ 前の作業がエラーで終わったので止めています（▶ で続きを送ります）")
        case .refused(let why): return L("⏸ 送れませんでした: %@", why ?? L("不明"))
        case .targetMissing: return L("⏸ 送り先のおもちがいません。送り先を選び直してください")
        case .restarted: return L("⏸ アプリを終了したので止めています（▶ で続きを送ります）")
        }
    }

    /// 送り先のおもちのチャットに出す 1 行（ほかのおもちの予約で作業中・順番待ち）
    func noteForTarget(_ agent: UUID) -> String? {
        for (o, q) in queues where o != agent && q.watching == agent {
            return L("🔗 %@ の予約の続きを作業中", host?.queueAgentName(o) ?? "?")
        }
        let waiting = queues.filter { o, q in o != agent && !q.isPaused && q.watching == nil && (q.items.first?.target ?? o) == agent }
        if let (o, _) = waiting.first { return L("🔗 %@ の予約が、この作業の後に控えています", host?.queueAgentName(o) ?? "?") }
        return nil
    }

    /// omochi://debug 用
    func debugLines() -> [String] {
        queues.values.filter { !$0.items.isEmpty || $0.watching != nil || $0.isPaused }.map { q in
            "queue \(q.owner.uuidString.prefix(8)) items=\(q.items.count) watching=\(q.watching.map { String($0.uuidString.prefix(8)) } ?? "-") paused=\(q.pause.map { "\($0)" } ?? "-") sent=\(q.sent) targets=\(q.items.map { $0.target.map { String($0.uuidString.prefix(8)) } ?? "self" }.joined(separator: ","))"
        }
    }

    // MARK: - 内部

    /// 予約が空になったら数を戻す。待つものも無ければ止めた理由も消す
    private func settle(_ owner: UUID) {
        guard var q = queues[owner] else { return }
        if q.items.isEmpty {
            if q.watching == nil { q.pause = nil; q.sent = 0; q.lastResult = nil }
            if q.watching == nil { queues[owner] = nil; return }
        }
        queues[owner] = q
    }

    private func changed(_ owner: UUID, also: [UUID] = []) {
        save()
        var s = Set(also)
        s.insert(owner)
        for it in queues[owner]?.items ?? [] { if let t = it.target { s.insert(t) } }
        if let w = queues[owner]?.watching { s.insert(w) }
        host?.queuesChanged(s)
    }

    private struct Saved: Codable { var queues: [PromptQueue] }

    private func load() {
        guard let file, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        for var q in s.queues where !q.items.isEmpty {
            // 前回の終了で作業は中断されているので、勝手に続きを送らない
            q.watching = nil
            q.skipNextStop = false
            if q.pause == nil { q.pause = .restarted }
            queues[q.owner] = q
        }
    }

    private func save() {
        guard let file else { return }
        let s = Saved(queues: queues.values.filter { !$0.items.isEmpty }.sorted { $0.owner.uuidString < $1.owner.uuidString })
        if s.queues.isEmpty { try? FileManager.default.removeItem(at: file); return }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) }
    }
}
