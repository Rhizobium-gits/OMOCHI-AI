import AppKit

/// 開発用の「使い方の記録」（この Mac の開発用ビルドだけ）。
///
/// - `OMOCHI_DEV_JOURNAL=1 scripts/install.sh`（または `scripts/build.sh --dev-journal`）でビルドしたときだけ、
///   `-DOMOCHI_DEV_JOURNAL` が付いて記録の部分が入る。配布する版（`scripts/release.sh`・CI）には入らず、何も書かない
/// - どこにも送らない。データフォルダの `dev-journal/` に、日ごとの JSONL（本人だけが読める 0600）で書く
/// - 指示の本文・ファイルのパスは書かない（指示は長さと依頼の種類のタグだけ）
/// - 始めてから 7 日で止まる（メニューの 📓 から延長・一時停止）。まとめは `scripts/dev/journal-report.py`
enum DevJournal {
    #if OMOCHI_DEV_JOURNAL
    static let compiledIn = true
    #else
    static let compiledIn = false
    #endif
    static let defaultDays = 7

    /// 記録する（開発用ビルドで、記録の期間中のときだけ書く。そうでなければ何もしない）
    static func log(_ event: String, _ props: [String: Any] = [:]) {
        #if OMOCHI_DEV_JOURNAL
        Writer.shared.write(event, props)
        #endif
    }

    // MARK: - 書き方（どのビルドにも入る、画面やファイルを使わない部分。テストで確かめる）

    /// 1 行の JSON（キーは並べ替える。値は文字列・数・真偽・それらの配列だけにする）
    static func line(_ event: String, _ props: [String: Any], at date: Date, session: String) -> String? {
        var obj: [String: Any] = ["t": iso.string(from: date), "ev": event, "run": session]
        for (k, v) in props where k != "t" && k != "ev" && k != "run" {
            if let c = clean(v) { obj[k] = c }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func clean(_ v: Any) -> Any? {
        switch v {
        case let s as String: return s.count > 120 ? String(s.prefix(120)) + "…" : s
        case let b as Bool: return b
        case let n as Int: return n
        case let d as Double: return d.isFinite ? (d * 1000).rounded() / 1000 : nil
        case let f as CGFloat: return clean(Double(f))
        case let a as [String]: return Array(a.prefix(20)).map { clean($0) as? String ?? "" }
        default: return nil
        }
    }

    /// 指示の要約（本文は残さない）：長さ・依頼の種類・どこから来た指示か・何を添えたか
    static func promptSummary(_ text: String) -> [String: Any] {
        let typed = AgentChatController.typedText(text)
        var kind = "user"
        if text.hasPrefix(TeamCoordinator.requestMarker) { kind = "team" }
        else if text.hasPrefix(MochiPlay.warmPrefix) { kind = "warm" }
        else if text.hasPrefix(MochiPlay.mergePrefix) { kind = "merge" }
        else if text.hasPrefix(MochiPlay.dangoPrefix) { kind = "dango" }
        else if text.trimmingCharacters(in: .whitespacesAndNewlines) == MochiPlay.compactCommand { kind = "compact" }
        return [
            "kind": kind,
            "chars": typed.count,
            "lines": typed.split(separator: "\n").count,
            "tags": TaskFeatures.extract(typed).tags.sorted(),
            "attach": text.contains(AgentChatController.attachMarker),
            "screen": text.contains(ScreenContext.marker),
            "passed": text.contains(PromptQueues.resultMarker),
            "fork": text.contains(MochiPlay.forkMarker),
        ]
    }

    /// エラーの種類（本文は残さない）
    static func errorKind(_ s: String?) -> String {
        guard let s = s?.lowercased(), !s.isEmpty else { return "none" }
        let table: [(String, [String])] = [
            ("login", ["ログイン", "login", "logged", "auth", "credential"]),
            ("billing", ["従量課金", "api key", "api キー"]),
            ("limit", ["rate limit", "usage limit", "quota", "上限", "limit reached", "429"]),
            ("not-installed", ["見つかりません", "入っていません", "not found", "no such file"]),
            ("network", ["network", "timed out", "timeout", "connection", "offline", "ネットワーク"]),
            ("interrupted", ["中断", "interrupted", "sigterm", "killed"]),
            ("trust", ["trusted directory", "信頼"]),
            ("session", ["session id", "already in use", "no conversation"]),
        ]
        for (k, words) in table where words.contains(where: { s.contains($0) }) { return k }
        return "other"
    }

    /// 記録の期間（始めた日から days 日）。止めていなければ、その間だけ書く
    struct Period: Codable, Equatable {
        var started: Date
        var days: Int = DevJournal.defaultDays
        var paused: Bool = false

        func recording(at now: Date) -> Bool { !paused && now < ends }
        var ends: Date { started.addingTimeInterval(Double(days) * 86400) }
        /// 何日目か（1 から）
        func day(at now: Date) -> Int { max(1, Int(now.timeIntervalSince(started) / 86400) + 1) }
    }

    /// 日ごとのファイルの名前
    static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date) + ".jsonl"
    }

    #if OMOCHI_DEV_JOURNAL
    /// データフォルダの dev-journal/ に書く（書くのは裏のキューで。アプリの動きを待たせない）
    final class Writer {
        static let shared = Writer()
        let dir = AppPaths.dataDir.appendingPathComponent("dev-journal", isDirectory: true)
        private let queue = DispatchQueue(label: "omochi.devjournal", qos: .utility)
        private let session = String(UUID().uuidString.prefix(8)).lowercased()
        private(set) var period: Period
        private(set) var count = 0
        private var periodURL: URL { dir.appendingPathComponent("period.json") }

        private init() {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent("period.json")
            if let d = try? Data(contentsOf: url), let p = try? JSONDecoder.journal.decode(Period.self, from: d) {
                period = p
            } else {
                period = Period(started: Date())
                if let d = try? JSONEncoder.journal.encode(period) { try? d.write(to: url, options: .atomic) }
            }
        }

        var recording: Bool { period.recording(at: Date()) }

        func write(_ event: String, _ props: [String: Any]) {
            let now = Date()
            guard period.recording(at: now), let l = DevJournal.line(event, props, at: now, session: session) else { return }
            count += 1
            let url = dir.appendingPathComponent(DevJournal.fileName(for: now))
            queue.async {
                let fm = FileManager.default
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                guard let h = try? FileHandle(forWritingTo: url) else { return }
                h.seekToEndOfFile()
                h.write(Data((l + "\n").utf8))
                try? h.close()
            }
        }

        func update(_ change: (inout Period) -> Void) {
            change(&period)
            if let d = try? JSONEncoder.journal.encode(period) { try? d.write(to: periodURL, options: .atomic) }
        }

        /// 📓 メニュー（メニューバーのおもちのメニューの最後のほうに出す）
        func menuItem() -> NSMenuItem {
            let now = Date()
            let item = NSMenuItem(title: recording ? L("📓 開発用の記録（%ld 日目 / %ld 日）", period.day(at: now), period.days)
                                                    : L("📓 開発用の記録（止まっています）"), action: nil, keyEquivalent: "")
            let m = NSMenu()
            m.autoenablesItems = false
            m.addItem(.header(L("この Mac の開発用ビルドだけ。どこにも送らず、指示の本文は残しません")))
            m.addItem(ClosureMenuItem(L("記録のフォルダを開く")) { [dir] in NSWorkspace.shared.open(dir) })
            if period.paused {
                m.addItem(ClosureMenuItem(L("再開する")) { Writer.shared.update { $0.paused = false } })
            } else if recording {
                m.addItem(ClosureMenuItem(L("一時停止する")) { Writer.shared.update { $0.paused = true } })
            }
            m.addItem(ClosureMenuItem(L("あと 7 日続ける")) {
                Writer.shared.update { p in
                    p.paused = false
                    let left = max(0, p.ends.timeIntervalSinceNow)
                    p.days = Int(ceil((Date().timeIntervalSince(p.started) + left) / 86400)) + 7
                }
            })
            item.submenu = m
            return item
        }
    }
    #endif
}

private extension JSONDecoder {
    static var journal: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private extension JSONEncoder {
    static var journal: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
