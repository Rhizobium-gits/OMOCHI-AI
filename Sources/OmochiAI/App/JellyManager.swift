import AppKit
import CryptoKit

/// すべてのおもちの生成・配置・表示・永続化を管理する。
/// Phase 2 ではここに AgentRuntime（エージェントごとのプロセス管理）がぶら下がる。
final class JellyManager {
    let store: Store
    private(set) var settings: AppSettings
    private(set) var controllers: [JellyController] = []
    /// メニューバー表示の更新など
    var onChange: (() -> Void)?

    private var pointerTimer: Timer?
    private var lastDragMods: NSEvent.ModifierFlags = []
    /// おもちごとのエージェント（セッション・プロセス・履歴）
    var runtimes: [UUID: AgentRuntime] = [:]
    /// おもちを消しても実行中なら最後まで動かすためのもの
    private var detached: [AgentRuntime] = []
    /// おもちごとのチャットウィンドウ
    var chats: [UUID: AgentChatController] = [:]
    /// エージェント同士の分業（つながり・依頼・受け渡しの表示）
    private(set) var team: TeamCoordinator?
    /// チャットの予約（いまの作業が終わったら送る指示。ほかのおもちへつなげることもできる）
    private(set) lazy var queues: PromptQueues = {
        let q = PromptQueues(file: store.dir.appendingPathComponent("queues.json"))
        q.host = self
        return q
    }()
    /// システムの音の聞き取り（同時に 1 つ）。値は AudioTranscriber（macOS 26 以降）
    private var listener: (agent: UUID, object: AnyObject)?
    /// 直近の文字起こしファイル（エージェントごと）
    private(set) var lastTranscript: [UUID: URL] = [:]

    // MARK: お餅の性質（MochiActions.swift）
    /// ちぎっている途中（⌘ ドラッグ）：元のおもちと、引っぱり出している分身
    var tearState: (origin: UUID, clone: UUID)?
    /// 串だんご（串に刺さっているおもちの並び）と、保存したレシピ
    lazy var skewers: [Skewer] = store.load([Skewer].self, name: "skewers.json") ?? []
    lazy var recipes: [DangoRecipe] = store.load([DangoRecipe].self, name: "recipes.json") ?? []
    var lookTimer: Timer?
    var dangoWindow: DangoWindowController?
    var makiWindow: MochiMakiWindowController?
    /// 動かしている途中のおもち（なめらかに置き直す）
    var moveTimer: Timer?

    private var lastPointer = NSPoint(x: -1, y: -1)
    private var pointerIdleTicks = 0
    /// 窓の見張り（pollPointer の回数で、約 2 秒ごと）
    private var windowCheckTicks = 0
    private var lastWindowFixLog: Date = .distantPast
    /// 前に確かめたとき画面に出ていなかったおもち（出し直しても出ないまま＝消灯中のディスプレイなど。2 回目からは数えない）
    private var lostMochi: Set<UUID> = []
    private var saveScheduled = false

    var layout: AvatarLayout { AvatarFactory.layout(settings.avatarStyle, scale: settings.jellyScale) }
    var windowSize: CGSize { layout.size }

    init(store: Store) {
        self.store = store
        self.settings = store.loadSettings()
        BillingGuard.allowAPI = settings.allowAPIBilling
    }

    // MARK: 起動

    func start() {
        var records = store.loadJellies()
        if records.isEmpty { records = [makeRecord()] }
        for r in records { _ = addController(r) }
        ensureOnScreen()
        if !settings.allHidden {
            for c in controllers where !c.record.hidden { c.show(animated: true) }
        }
        startPointerTracking()
        startLookTimer()
        DevJournal.log("launch", ["version": AppInfo.version, "mochi": controllers.count, "style": settings.avatarStyle.rawValue,
                                  "engine": settings.engine.rawValue, "team": settings.teamEnabled, "org": settings.orgMode,
                                  "skewers": skewers.count, "recipes": recipes.count])
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ensureOnScreen()
            self?.team?.refresh()
            self?.reassertWindowsSoon("screens")
        }
        // スペース（デスクトップ・ほかのアプリのフル画面）を切り替えた・スリープから戻った・画面がついた：
        // おもちと糸がいまのスペースに出ているかを確かめ直す（切り替えの動きが終わってから）
        let ws = NSWorkspace.shared.notificationCenter
        for (name, reason) in [(NSWorkspace.activeSpaceDidChangeNotification, "space"), (NSWorkspace.didWakeNotification, "wake"),
                               (NSWorkspace.screensDidWakeNotification, "screens-wake"), (NSWorkspace.sessionDidBecomeActiveNotification, "session")] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reassertWindowsSoon(reason) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reassertWindowsSoon("unhide")
        }
        save()
        team = TeamCoordinator(manager: self, store: store)
        team?.org.onChange = { [weak self] in self?.onChange?() }
        team?.start()
        EngineAuth.shared.onChange = { [weak self] in
            self?.accountsWindow?.refresh()
            self?.onChange?()
        }
        // サムネイル・Web のプレビューができたら、開いているチャットを描き直す（続けて届いても 1 回に）
        ChatMediaCache.shared.onUpdate = { [weak self] in self?.scheduleTranscriptReload() }
        // モデルの一覧が届いたら、開いているチャットの選択肢を作り直す
        EngineModelCatalog.shared.onChange = { [weak self] in
            guard let self else { return }
            for (_, chat) in self.chats { chat.refresh() }
        }
        // 使う AI のログイン状態を先に確かめておく（最初の指示で待たないように）
        refreshEngineStatus()
        // 見守り（おもちごとに既定オフ。オンのおもちがいるときだけ動く）
        ScreenWatcher.shared.isActive = { [weak self] in self?.runtimes.values.contains { $0.watchScreen } ?? false }
        ScreenWatcher.shared.ignoredApps = { [weak self] in Set(self?.settings.watchIgnoredApps ?? []) }
        ScreenWatcher.shared.onFinding = { [weak self] f in self?.handleWatchFinding(f) }
        DispatchQueue.main.async { ScreenWatcher.shared.refresh() }
    }

    // MARK: - 見守り（画面のエラーっぽい表示に気づいたら聞く）

    private var watchBubble: WatchBubble?
    private var watchImages: [URL: Timer] = [:]

    /// 見守っているおもち（隠しているものは除く）
    var watchingControllers: [JellyController] {
        controllers.filter { runtimes[$0.record.id]?.watchScreen == true && !$0.record.hidden }.sorted { $0.record.number < $1.record.number }
    }

    func setWatching(_ c: JellyController, _ on: Bool) {
        guard let rt = runtimes[c.record.id] else { return }
        rt.watchScreen = on
        ScreenWatcher.shared.refresh()
        chats[c.record.id]?.refresh()
        AppLog.write("watch \(on ? "on" : "off"): agent \(c.record.number)")
        guard on, !CGPreflightScreenCaptureAccess() else { return }
        // 画面収録の許可が無いと見られない（確認は起動中 1 回だけ）
        _ = DesktopControl.requestScreenRecordingOnce()
        if CGPreflightScreenCaptureAccess() { return }
        let a = NSAlert()
        a.messageText = L("見守りには画面収録の許可が必要です")
        a.informativeText = L("前面のウィンドウを Mac の中で読むために使います（どこにも送りません）。") + "\n\n" + DesktopControl.screenRecordingHint
        a.addButton(withTitle: L("🔐 権限の画面を開く"))
        a.addButton(withTitle: L("あとで"))
        if ActiveSpace.runModal(a) == .alertFirstButtonReturn { showPermissions() }
    }

    func stopAllWatching() {
        for rt in runtimes.values where rt.watchScreen { rt.watchScreen = false }
        ScreenWatcher.shared.refresh()
        watchBubble?.close()
        watchBubble = nil
        for (_, chat) in chats { chat.refresh() }
    }

    func unignoreWatchApp(_ bundleID: String) {
        updateSettings { $0.watchIgnoredApps.removeAll { $0 == bundleID } }
    }

    /// アップデートの自動確認で新しい版が見つかったとき：見えているおもちの上に吹き出しで知らせる（入力先は奪わない）。
    /// おもちが 1 体も見えていなければ出さない（メニューの「新しい版 … があります…」で分かる）
    private var updateBubble: WatchBubble?

    func showUpdateBubble(_ tag: String) {
        guard updateBubble == nil, !settings.allHidden,
              let c = controllers.filter({ !$0.record.hidden }).min(by: { $0.record.number < $1.record.number }) else { return }
        let text = WatchBubble.Text(title: L("新しい版 %@ が出たよ", tag),
                                    detail: L("いまは %@。「見る」で変わったところを見てから、アップデートするか決められます", AppInfo.version),
                                    closeTip: L("閉じる（次の確認のときにまた知らせます）"),
                                    ignore: L("この版は知らせない"), note: nil)
        let b = WatchBubble(text, accent: c.record.color.nsColor, near: c.panel.frame, autoClose: 600,
            onShow: { [weak self] in
                self?.updateBubble = nil
                UpdateChecker.check(manager: self)
            },
            onDismiss: { [weak self] in self?.updateBubble = nil },
            onIgnoreApp: { [weak self] in
                self?.updateBubble = nil
                self?.updateSettings { $0.skippedUpdateVersion = tag }
            })
        updateBubble = b
        b.present()
        AppLog.write("update bubble: \(tag) on agent \(c.record.number)")
    }

    private func handleWatchFinding(_ f: WatchFinding, target: JellyController? = nil) {
        guard watchBubble == nil, let c = target ?? watchingControllers.first, let rt = runtimes[c.record.id] else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        // 送るまでは「watch-pending-」（押されないままアプリが終わっても、次の起動と定期の片付けで消える）
        let url = rt.dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("watch-pending-\(stamp).png")
        guard ScreenWatcher.savePNG(f.image, to: url) else { return }
        // 押されなければ 10 分で消す
        watchImages[url] = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in self?.discardWatchImage(url) }
        let b = WatchBubble(
            .watch(appName: f.appName, snippet: f.snippet), accent: c.record.color.nsColor, near: c.panel.frame,
            onShow: { [weak self, weak c] in
                guard let self else { return }
                self.watchBubble = nil
                guard let c else { self.discardWatchImage(url); return }
                self.watchImages[url]?.invalidate()
                self.watchImages[url] = nil     // 送ったものは添付として残す（画面の画像と同じく 7 日で片付く）
                let sent = url.deletingLastPathComponent().appendingPathComponent("watch-\(stamp).png")
                let image = (try? FileManager.default.moveItem(at: url, to: sent)) != nil ? sent : url
                self.openChat(for: c)
                self.chats[c.record.id]?.sendWatchFinding(image: image, appName: f.appName, windowTitle: f.windowTitle)
                AppLog.write("watch: sent to agent \(c.record.number)")
            },
            onDismiss: { [weak self] in
                self?.watchBubble = nil
                self?.discardWatchImage(url)
                if let b = f.bundleID { ScreenWatcher.shared.quiet(b, for: 1800) }
            },
            onIgnoreApp: { [weak self] in
                guard let self else { return }
                self.watchBubble = nil
                self.discardWatchImage(url)
                if let b = f.bundleID, !b.isEmpty { self.updateSettings { if !$0.watchIgnoredApps.contains(b) { $0.watchIgnoredApps.append(b) } } }
            })
        watchBubble = b
        b.present()
        // 同じアプリではしばらく聞かない（✕ ならもっと長く）
        if let b = f.bundleID { ScreenWatcher.shared.quiet(b, for: 600) }
        // 認識した文字はログに書かない
        AppLog.write("watch: finding in \(f.bundleID ?? "?") → agent \(c.record.number)")
    }

    /// テスト用：見本の画像で吹き出しを出す（omochi://watchtest。自動化のときだけ）
    func debugWatchFinding() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 800, height: 200).fill()
        ("error: cannot find 'foo' in scope" as NSString).draw(at: NSPoint(x: 20, y: 90),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular), .foregroundColor: NSColor.systemRed])
        NSGraphicsContext.restoreGraphicsState()
        guard let img = rep.cgImage else { return }
        handleWatchFinding(WatchFinding(appName: "Terminal", bundleID: "com.apple.Terminal", windowTitle: "zsh",
                                        snippet: "error: cannot find 'foo' in scope", image: img, signature: UUID().uuidString),
                           target: watchingControllers.first ?? controllers.first)
    }

    private func discardWatchImage(_ url: URL) {
        watchImages[url]?.invalidate()
        watchImages[url] = nil
        try? FileManager.default.removeItem(at: url)
    }

    static let languageChanged = Notification.Name("OmochiLanguageChanged")

    /// メニューバーの「🧠 モデル（既定）」の名前（おもちごとに選んでいないときに使うモデル）
    var defaultModelName: String { JellyManager.modelSettingName(settings.model) }

    static func modelSettingName(_ m: String) -> String {
        if m.isEmpty { return L("Claude Code に任せる") }
        if m == ModelRouter.auto { return L("🤖 自動") }
        return ModelRouter.displayName(m)
    }

    /// 既定のモデル（設定の model）を変える。"" = Claude Code に任せる、"auto" = 自動
    func setDefaultModel(_ m: String) {
        updateSettings { $0.model = m }
        if m == ModelRouter.auto { refreshUsageForAutoModel() }
        for (_, chat) in chats { chat.refresh() }
    }

    /// 「自動」が Fable を使ってよいか決めるのに、今週の使用量を読んでおく（1 分以内に読んでいれば何もしない。モデルは呼ばない）
    func refreshUsageForAutoModel() {
        ClaudeAccount.shared.refreshIfStale(claudeOverride: settings.claudePath)
    }

    /// 表示の言語を変える。開いているチャットは作り直す（ボタンや案内の文字を新しい言語にする）
    func setLanguage(_ lang: AppLanguage) {
        guard lang != settings.language else { return }
        settings.language = lang
        L10n.setting = lang
        store.save(settings)
        let open = chats.filter { $0.value.isVisible }.map(\.key)
        for (_, chat) in chats { chat.dismiss() }
        chats.removeAll()
        for id in open { if let c = controllers.first(where: { $0.record.id == id }) { openChat(for: c, activate: false) } }
        chatWindowVisibilityChanged()
        team?.refresh()
        onChange?()
        NotificationCenter.default.post(name: JellyManager.languageChanged, object: nil)
        AppLog.write("language: \(lang.rawValue) -> \(L10n.current.rawValue)")
    }

    func makeRecord() -> JellyRecord {
        let ci = JellyManager.lowestFree(Set(controllers.map { $0.record.colorIndex }), from: 0)
        // 番号も色と同じく、今いるおもちで空いている一番小さいものを使う（消した番号は使い回すので増え続けない）
        let n = JellyManager.lowestFree(Set(controllers.map { $0.record.number }), from: 1)
        return JellyRecord(id: UUID(), number: n, colorIndex: ci, origin: nil,
                           hidden: false, state: .idle, createdAt: Date())
    }

    static func lowestFree(_ used: Set<Int>, from start: Int) -> Int {
        var n = start
        while used.contains(n) { n += 1 }
        return n
    }

    /// 番号を 1 から詰め直すときの対応（今の番号の小さい順に 1, 2, 3…）。変わらないものは含めない
    static func compactNumbers(_ numbers: [Int]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (i, n) in numbers.sorted().enumerated() where n != i + 1 { map[n] = i + 1 }
        return map
    }

    /// 番号が 1, 2, 3… と詰まっているか（メニューの「番号を 1 から振り直す」を出すかどうか）
    var numbersAreCompact: Bool { JellyManager.compactNumbers(controllers.map(\.record.number)).isEmpty }

    /// 番号を 1 から振り直す（今の番号の小さい順）。名前を付けたおもちは表示名が変わらない
    func renumber() {
        let map = JellyManager.compactNumbers(controllers.map(\.record.number))
        guard !map.isEmpty else { return }
        for c in controllers {
            guard let n = map[c.record.number] else { continue }
            c.update { $0.number = n }
            c.panel.title = c.record.title
            chats[c.record.id]?.refresh()
        }
        team?.refresh()
        save()
        onChange?()
        AppLog.write("renumber: \(map.count) agents")
    }

    func addController(_ r: JellyRecord) -> JellyController {
        let avatar = AvatarFactory.make(settings.avatarStyle, record: r, scale: settings.jellyScale,
                                        maxFPS: settings.maxFPS, calmFPS: settings.calmFPS)
        let c = JellyController(record: r, avatar: avatar, manager: self)
        controllers.append(c)
        attachRuntime(to: c)
        if r.origin == nil {
            c.moveTo(freeSlotOrigin(excluding: c), persist: true)
        } else {
            c.panel.setFrameOrigin(r.origin!)
        }
        return c
    }

    // MARK: 生成・削除

    /// 新しいおもち（エージェント）を生成する。既存のおもちには一切触れない。
    @discardableResult
    func spawn(openChat open: Bool = true, activate: Bool = true) -> JellyController {
        if settings.allHidden { setAllHidden(false) }
        let c = addController(makeRecord())
        c.show(animated: true)
        save()
        onChange?()
        DevJournal.log("spawn", ["agent": c.record.number, "total": controllers.count, "chat": open])
        // 生成したらすぐ指示を打ち込めるように（activate: false は外からの URL。入力先は奪わない）
        if open { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak c] in
            guard let self, let c, self.controllers.contains(where: { $0 === c }) else { return }
            self.openChat(for: c, quickCapture: true, activate: activate)
        } }
        return c
    }

    // MARK: エージェント

    /// おもちのエンジン（nil = 既定の「使う AI」）のバックエンド。CLI が見つからない・使えない版なら nil
    func backend(for e: AgentEngine?) -> AgentBackend? {
        switch e ?? settings.engine {
        case .claude:
            return backend()
        case .codex:
            guard let i = CLILocator.find(.codex, override: settings.codexPath), i.missing == nil else { return nil }
            return CodexBackend(install: i, model: settings.codexModel.isEmpty ? nil : settings.codexModel)
        case .gemini:
            guard let i = CLILocator.find(.gemini, override: settings.geminiPath), i.missing == nil else { return nil }
            return GeminiBackend(install: i, model: settings.geminiModel.isEmpty ? nil : settings.geminiModel)
        }
    }

    func cliPath(_ e: AgentEngine) -> String? {
        switch e {
        case .claude: return settings.claudePath
        case .codex: return settings.codexPath
        case .gemini: return settings.geminiPath
        }
    }

    var cliPaths: [AgentEngine: String] { [.claude: settings.claudePath, .codex: settings.codexPath, .gemini: settings.geminiPath] }

    /// 実行の前の確認：サブスクリプション（アカウント）でログインしているときだけ動かす。
    /// API キー（従量課金）でログインしているときは、ユーザーがメニューで許可していなければ動かさない（勝手に課金しない。Claude も同じ）
    func preflight(_ b: AgentBackend) -> String? {
        let e = b.engine
        var s = EngineAuth.shared.status(e, claudePath: settings.claudePath, cliPath: cliPath(e))
        // 止める前に、いま確かめ直す（ターミナルでログインした直後でも、覚えていた古い状態で止めない）
        if !s.usable { s = EngineAuth.shared.status(e, claudePath: settings.claudePath, cliPath: cliPath(e), maxAge: 0) }
        return JellyManager.preflightMessage(e, s, allowAPI: settings.allowAPIBilling)
    }

    /// 動かさない理由（テストあり）。nil なら動かしてよい
    static func preflightMessage(_ e: AgentEngine, _ s: EngineStatus, allowAPI: Bool) -> String? {
        switch s.login {
        case .subscription:
            return nil
        case .paidAPI(let how):
            return allowAPI ? nil : L("%@ は %@（従量課金）でログインしているので使いません（勝手に課金しないため）。%@ でログインし直すか、メニューバーのおもち › 🔑 アカウントと AI で「API キー（従量課金）での利用を許可」をオンにしてください", e.displayName, how, e.accountKind)
        case .loggedOut:
            return L("%@ にログインしていません。メニューバーのおもち › 🔑 アカウントと AI から、%@ でログインしてください", e.displayName, e.accountKind)
        case .notInstalled:
            return L("%@ が入っていません。メニューバーのおもち › 🔑 アカウントと AI に、入れ方があります", e.cliTitle)
        case .unsupported(let m):
            return L("この版の %@ では使えません（%@ がありません）。%@ を新しくしてください", e.cliTitle, m, e.cliTitle)
        case .unknown:
            // 確かめられなかったとき（CLI の一時的な不調など）は止めない。API キーの環境変数は渡していないので、勝手に従量課金にはならない
            return nil
        }
    }

    /// Codex・Gemini のモデルの一覧を、古ければ裏で読み直す（モデルは呼ばない）
    func refreshModels(_ e: AgentEngine, force: Bool = false) {
        guard e != .claude else { return }
        let path = cliPath(e)
        EngineModelCatalog.shared.refresh(e, cli: { CLILocator.find(e, override: path)?.url }, force: force)
    }

    /// ChatGPT・Gemini の既定のモデル（"" = CLI の既定）
    func setDefaultModel(_ m: String, for e: AgentEngine) {
        switch e {
        case .claude: setDefaultModel(m)
        case .codex: updateSettings { $0.codexModel = m }
        case .gemini: updateSettings { $0.geminiModel = m }
        }
        for (_, chat) in chats { chat.refresh() }
    }

    func defaultModelID(_ e: AgentEngine) -> String {
        switch e {
        case .claude: return settings.model
        case .codex: return settings.codexModel
        case .gemini: return settings.geminiModel
        }
    }

    /// その AI の既定のモデルの名前（チャット・メニューの表示用）
    func defaultModelLabel(_ e: AgentEngine) -> String {
        if e == .claude { return defaultModelName }
        let id = defaultModelID(e)
        if id.isEmpty { return L("%@ の設定", e.cliTitle) }
        return EngineModelCatalog.shared.model(e, id: id)?.name ?? id
    }

    func reloadOpenChats() {
        for (_, chat) in chats where chat.isVisible { chat.reloadTranscript() }
    }

    private var transcriptReload: DispatchWorkItem?
    private func scheduleTranscriptReload() {
        transcriptReload?.cancel()
        let w = DispatchWorkItem { [weak self] in
            for (_, chat) in self?.chats ?? [:] where chat.isVisible { chat.reloadTranscript() }
        }
        transcriptReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// 使う AI（既定）を変える
    func setDefaultEngine(_ e: AgentEngine) {
        updateSettings { $0.engine = e }
        for (_, chat) in chats { chat.refresh() }
        AppLog.write("engine default: \(e.rawValue)")
    }

    /// API キー（従量課金）での利用の許可。オンにするときは本人に確かめる
    func setAllowAPIBilling(_ on: Bool) {
        if on {
            let a = NSAlert()
            a.messageText = L("API キー（従量課金）での利用を許可しますか？")
            a.informativeText = L("オンにすると、API キーでログインしている AI もエージェントとして動き、シェルの設定にある API キー（ANTHROPIC_API_KEY・OPENAI_API_KEY・GEMINI_API_KEY など）も CLI に渡します。使った分だけ、それぞれの API の料金がかかります。ふだんはオフのまま、サブスクリプション（Claude・ChatGPT・Google のアカウント）でログインして使ってください。")
            a.alertStyle = .warning
            a.addButton(withTitle: L("許可する"))
            a.addButton(withTitle: L("キャンセル"))
            guard ActiveSpace.runModal(a) == .alertFirstButtonReturn else { return }
        }
        updateSettings { $0.allowAPIBilling = on }
        BillingGuard.allowAPI = on
        refreshEngineStatus()
        accountsWindow?.refresh()
        AppLog.write("allowAPIBilling: \(on)")
    }

    /// ログイン状態を裏で確かめ直す
    func refreshEngineStatus(_ engines: [AgentEngine] = AgentEngine.allCases, relocate: Bool = false) {
        EngineAuth.shared.refresh(engines, claudePath: settings.claudePath, cliPaths: cliPaths, relocate: relocate)
    }

    /// AI ごと・モデルごとの使用量（端末内）
    lazy var usage = UsageLedger(url: store.dir.appendingPathComponent("usage.json"))

    /// 使用量を数えるときのアカウント（メールは保存しない。Claude はメールの短いハッシュ、ほかはサービス名）
    func usageAccount(_ e: AgentEngine) -> String {
        switch e {
        case .claude:
            // メニューのアカウント欄、なければ起動時に確かめたログインの状態（「メール · プラン」）から
            let email = ClaudeAccount.shared.snapshot?.account?.email
                ?? EngineAuth.shared.cached(.claude)?.account?.components(separatedBy: " · ").first { $0.contains("@") }
            guard let email else { return "claude" }
            return "claude#" + JellyManager.shortHash(email)
        case .codex: return "ChatGPT"
        case .gemini: return "Google"
        }
    }

    static func shortHash(_ s: String) -> String {
        SHA256.hash(data: Data(s.lowercased().utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// 使用量の表に出すアカウントの名前（いまログインしている Claude のアカウントならメール）
    func usageAccountLabel(_ stored: String, engine: AgentEngine) -> String {
        let email = ClaudeAccount.shared.snapshot?.account?.email
            ?? EngineAuth.shared.cached(.claude)?.account?.components(separatedBy: " · ").first { $0.contains("@") }
        if engine == .claude, stored.hasPrefix("claude#"), let email, stored == "claude#" + JellyManager.shortHash(email) {
            return email
        }
        if stored.hasPrefix("claude#") { return L("別のアカウント（%@）", String(stored.dropFirst("claude#".count))) }
        if stored == "-" || stored == "claude" { return "" }
        return stored
    }

    /// 「アカウントと AI」の画面（初めての起動のときにも出す）
    private var accountsWindow: AccountsWindowController?

    func showAccounts() {
        if accountsWindow == nil {
            let w = AccountsWindowController(manager: self)
            accountsWindow = w
            EngineAuth.shared.onChange = { [weak self] in
                self?.accountsWindow?.refresh()
                self?.onChange?()
            }
        }
        refreshEngineStatus(relocate: true)
        accountsWindow?.show()
    }

    /// その AI の公式のログインをターミナルで開く（OMOCHI AI はパスワード・トークン・API キーを扱わない）。
    /// 入っていなければ、許可を求めてから入れて、続けてログインする
    func openLogin(_ e: AgentEngine, folder: URL? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cli: URL?
            switch e {
            case .claude: cli = ClaudeLocator.best(override: self.settings.claudePath)?.url
            case .codex: cli = CLILocator.find(.codex, override: self.settings.codexPath, maxAge: 0)?.url
            case .gemini: cli = CLILocator.find(.gemini, override: self.settings.geminiPath, maxAge: 0)?.url
            }
            DispatchQueue.main.async {
                guard let cli else { self.offerInstall(e); return }
                if !EngineLogin.open(e, cli: cli, folder: folder, allowAPI: self.settings.allowAPIBilling) { NSSound.beep() }
                AppLog.write("login opened: \(e.rawValue)\(folder == nil ? "" : " (folder)")")
            }
        }
    }

    /// CLI を入れるかを聞く。許可されたら、そのコマンドをターミナルで実行し、続けてログインを始める
    func offerInstall(_ e: AgentEngine) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let npm = e == .claude ? nil : EngineInstall.findTool("npm")
            let prefix = npm.flatMap { EngineInstall.npmPrefix($0) }
            let brew = e == .claude ? nil : EngineInstall.findTool("brew")
            let plan = EngineInstall.plan(e, npm: npm, npmWritable: prefix?.writable ?? false, brew: brew)
            DispatchQueue.main.async { self.askInstall(e, plan: plan, npmPrefix: prefix?.path) }
        }
    }

    private func askInstall(_ e: AgentEngine, plan: EngineInstall.Plan?, npmPrefix: String?) {
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        guard let plan else {
            a.messageText = L("%@ が入っていません", e.cliTitle)
            a.informativeText = (e == .codex
                ? L("ChatGPT のデスクトップアプリを入れて ChatGPT にログインすると、その中の Codex CLI をそのまま使えます。") + "\n\n" : "")
                + L("npm（Node.js）も Homebrew も見つからないため、ここからは入れられません。公式の案内に従って入れてから、もう一度ログインしてください。")
            a.addButton(withTitle: L("公式の案内を開く"))
            a.addButton(withTitle: L("閉じる"))
            if ActiveSpace.runModal(a) == .alertFirstButtonReturn { NSWorkspace.shared.open(e.setupURL) }
            return
        }
        let whereNote: String
        switch plan.tool {
        case .official: whereNote = L("Anthropic の公式インストーラで、あなたのホームの ~/.local/bin に入れます。")
        case .npm: whereNote = L("npm の公式パッケージを、npm のグローバル（%@）に入れます。", npmPrefix ?? "npm prefix -g")
        case .brew: whereNote = L("Homebrew の公式パッケージとして入れます。")
        }
        a.messageText = L("%@ を入れてログインしますか？", e.cliTitle)
        a.informativeText = L("%@ が入っていません。許可すると、ターミナルで次のコマンドを実行して入れ、続けてログインを始めます。あとはブラウザでログインするだけです。", e.cliTitle)
            + "\n\n" + plan.command + "\n\n" + whereNote + "\n"
            + L("管理者のパスワード（sudo）は使いません。OMOCHI AI はパスワード・API キーを扱いません。")
        a.addButton(withTitle: L("入れてログイン"))
        a.addButton(withTitle: L("公式の案内を開く"))
        a.addButton(withTitle: L("キャンセル"))
        switch ActiveSpace.runModal(a) {
        case .alertFirstButtonReturn:
            guard EngineInstall.open(plan, allowAPI: settings.allowAPIBilling) else { NSSound.beep(); return }
            let via: String
            switch plan.tool { case .official: via = "official"; case .npm: via = "npm"; case .brew: via = "brew" }
            AppLog.write("install opened: \(e.rawValue) via \(via)")
            watchInstall(e)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(e.setupURL)
        default: break
        }
    }

    /// 入れている間、入ったか・ログインできたかを見に行く（15 分まで）
    private var installWatch: [AgentEngine: Timer] = [:]
    private func watchInstall(_ e: AgentEngine) {
        installWatch[e]?.invalidate()
        let start = Date()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if EngineAuth.shared.cached(e)?.usable == true || Date().timeIntervalSince(start) > 900 {
                t.invalidate()
                self.installWatch[e] = nil
                return
            }
            self.refreshEngineStatus([e], relocate: true)
        }
        RunLoop.main.add(t, forMode: .common)
        installWatch[e] = t
    }

    func backend() -> AgentBackend? {
        guard let install = ClaudeLocator.best(override: settings.claudePath) else { return nil }
        let b = ClaudeCodeBackend(install: install, permissionMode: settings.permissionMode,
                                  model: settings.model.isEmpty ? nil : settings.model)
        if ClaudeCodeBackend.refusedSetting(settings.permissionMode, install: install), loggedRefusedMode != settings.permissionMode {
            loggedRefusedMode = settings.permissionMode
            AppLog.write("permissionMode \(settings.permissionMode.prefix(40)) refused; using \(b.permissionMode)")
        }
        return b
    }
    private var loggedRefusedMode: String?

    /// 画面表示用（待たない。起動直後は「確認中」）
    private var peekBackend: ClaudeCodeBackend? {
        guard case .found(let install) = ClaudeLocator.status(override: settings.claudePath) else { return nil }
        return ClaudeCodeBackend(install: install, permissionMode: settings.permissionMode,
                                 model: settings.model.isEmpty ? nil : settings.model)
    }

    var policyDescription: String {
        if let b = peekBackend { return b.policyDescription }
        if case .detecting = ClaudeLocator.status(override: settings.claudePath) { return L("Claude Code を確認中…") }
        return L("claude が見つかりません")
    }

    /// 実際に付ける --permission-mode（その版に auto が無ければ acceptEdits に落ちる）
    var effectivePermissionMode: String { peekBackend?.permissionMode ?? settings.permissionMode }

    /// settings.json の permissionMode を使わずに置き換えているとき、その値（bypassPermissions など）
    var refusedPermissionMode: String? {
        guard case .found(let install) = ClaudeLocator.status(override: settings.claudePath),
              ClaudeCodeBackend.refusedSetting(settings.permissionMode, install: install) else { return nil }
        return settings.permissionMode
    }

    var claudePathDescription: String {
        switch ClaudeLocator.status(override: settings.claudePath) {
        case .found(let i): return "\(i.versionString)  \(i.url.path)"
        case .detecting: return L("確認中…")
        case .notFound: return L("未検出（Claude Code をインストールしてください）")
        }
    }

    /// 起動直後に claude の検出（バージョン・オプション確認）を済ませておく
    func prefetchBackend() {
        let override = settings.claudePath
        DispatchQueue.global(qos: .utility).async { _ = ClaudeLocator.best(override: override) }
    }

    func runtime(for c: JellyController) -> AgentRuntime? { runtimes[c.record.id] }

    private func attachRuntime(to c: JellyController) {
        let rt = runtimes[c.record.id] ?? AgentRuntime(agentID: c.record.id, baseDir: store.dir,
                                                       backendProvider: { [weak self] e in self?.backend(for: e) })
        runtimes[c.record.id] = rt
        rt.preflight = { [weak self] b in self?.preflight(b) }
        let rid = c.record.id
        rt.extraDirs = { [weak self] in self?.team?.handoffDirs(for: rid) ?? [] }
        rt.onUsage = { [weak self] e, m, i, o, cached in
            guard let self else { return }
            self.usage.add(engine: e, model: m, account: self.usageAccount(e), input: i, output: o, cached: cached)
        }
        rt.defaultEngine = { [weak self] in self?.settings.engine ?? .claude }
        rt.onState = { [weak self, weak c] s in
            c?.setState(s)
            if let c { self?.refreshLook(c) }
            self?.onChange?()
        }
        rt.onLook = { [weak self, weak c] in
            guard let self, let c else { return }
            self.refreshLook(c)
            self.chats[c.record.id]?.refresh()
        }
        rt.onUpdate = { [weak self, weak c] in
            guard let self, let c else { return }
            self.chats[c.record.id]?.refresh()
        }
        let id = c.record.id
        rt.mcpPolicy = { [weak self] text, cwd, loadedInSession in
            let servers = ExternalMCP.serverNames(cwd: cwd)
            let mode = self?.settings.externalMCP ?? .auto
            switch mode {
            case .always:
                return .init(load: true, servers: servers, note: nil)
            case .never:
                return .init(load: false, servers: servers, note: ExternalMCP.notLoadedNote(servers, canLoad: false))
            case .auto:
                // 仲間からの依頼の文に名前が書いてあっても読み込まない（依頼文は Web ページなどに誘導された仲間が書いたかもしれない）。
                // 依頼元がユーザーの指示で外部ツールを読み込んで動いているときだけ、同じように読み込む
                if let from = self?.team?.requester(ofRunning: id) {
                    let fromRT = self?.controllers.first { $0.record.id == from }.flatMap { self?.runtime(for: $0) }
                    let fromLoaded = fromRT.map { $0.isRunning && !$0.externalLoaded.isEmpty } ?? false
                    if loadedInSession || fromLoaded { return .init(load: true, servers: servers, note: nil) }
                    return .init(load: false, servers: servers, note: ExternalMCP.notLoadedForRequestNote(servers))
                }
                // 本人が打った部分だけで決める（予約で渡した前の手順の結果・添付の欄はエージェントやファイルが書いたもの）
                let named = ExternalMCP.mentioned(in: AgentChatController.typedText(text), servers: servers)
                if loadedInSession || !named.isEmpty { return .init(load: true, servers: servers, note: nil) }
                return .init(load: false, servers: servers, note: ExternalMCP.notLoadedNote(servers, canLoad: true))
            }
        }
        rt.teamConfig = { [weak self, weak c, weak rt] in
            guard let self, let c, let rt else { return nil }
            return self.team?.runConfig(for: c, runtime: rt)
        }
        rt.onTurnEnded = { [weak self] turn in
            self?.team?.turnEnded(agent: id, turn: turn)
            // 予約の続き（このおもちの作業の終わりを待っていた予約があれば、次の行を送る）
            self?.queues.turnEnded(agent: id, state: turn.state, result: turn.state == .completed ? turn.result : (turn.error ?? turn.result))
        }
        // 前回の終了時に動いていた場合など、記録と状態がずれていたら記録側に合わせる
        if !rt.isRunning, let last = rt.lastTurn, c.record.state != last.state,
           !(c.record.state == .idle && last.state == .completed) {
            c.setState(last.state)
        } else if !rt.isRunning && (c.record.state == .thinking || c.record.state == .working) {
            c.setState(.idle)
        }
    }

    /// チャットウィンドウを開く。quickCapture（⌘L で作った直後）は、最初の指示を送ったら閉じて元の作業に戻す
    func openChat(for c: JellyController, quickCapture: Bool = false, activate: Bool = true) {
        guard let rt = runtimes[c.record.id] else { return }
        DevJournal.log("chat-open", ["agent": c.record.number, "quick": quickCapture, "engine": rt.effectiveEngine.rawValue])
        let chat: AgentChatController
        if let existing = chats[c.record.id] {
            chat = existing
            // ⌘L の小さな入力欄のまま開き直したときは、会話が読める普段の大きさに広げる
            if !existing.isVisible, !rt.turns.isEmpty || rt.sessionStarted,
               existing.window.frame.height < settings.chatHeight - 1 {
                existing.resizeKeepingTop(NSSize(width: settings.chatWidth, height: settings.chatHeight))
            }
        } else {
            let fresh = rt.turns.isEmpty && !rt.sessionStarted
            let size = fresh ? NSSize(width: settings.chatWidth, height: max(300, settings.chatHeight * 0.6))
                             : NSSize(width: settings.chatWidth, height: settings.chatHeight)
            chat = AgentChatController(jelly: c, runtime: rt, size: size)
            chat.manager = self
            chats[c.record.id] = chat
        }
        chat.closeAfterFirstSubmit = quickCapture
        chat.show(near: c, activate: activate)
    }

    /// デモ録画・自動テスト用：チャットの入力欄に 1 文字ずつ打ち込んで送信する（omochi://type）
    func typePrompt(_ text: String, into c: JellyController, cps: Double, quick: Bool = false, activate: Bool = true) {
        if chats[c.record.id]?.isVisible != true { openChat(for: c, quickCapture: quick, activate: activate) }
        chats[c.record.id]?.typeAndSubmit(text, cps: cps)
    }

    var claudeExecutable: URL? { ClaudeLocator.best(override: settings.claudePath)?.url }
    var supportsEffort: Bool {
        if case .found(let i) = ClaudeLocator.status(override: settings.claudePath) { return i.supportsEffort }
        return false
    }

    func rememberChatSize(_ size: NSSize) {
        guard size.width >= 380, size.height >= 240 else { return }
        settings.chatWidth = Double(size.width)
        settings.chatHeight = Double(size.height)
        scheduleSave()
    }

    /// チャットウィンドウが 1 つでも出て（またはしまわれて）いる間は普通のアプリとして Dock・⌘Tab・メニューバーに出す。
    /// showing：これから出す（まだ画面に無い）。Dock に出ないアプリ（accessory）は「Dock に出ず、メニューバーも持たない」ので、
    /// そのまま窓を出すと ⌘W・⌘M・⌃⌘F が効かず、隠れたりしまったりしたチャットに戻る道が無くなる。必ず出す前に普通のアプリにする
    func chatWindowVisibilityChanged(showing: Bool = false) {
        // アプリごと隠しているあいだ（⌘H）は窓が見えないだけなので、Dock から戻せるように普通のアプリのままにする
        if NSApp.isHidden && NSApp.activationPolicy() == .regular { return }
        let any = showing || chats.values.contains { $0.isVisible }
        let want: NSApplication.ActivationPolicy = any ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    /// omochi://debug 用：チャットの窓ごとの状態（出ている・しまった・フル画面・前面）
    func debugChatLines() -> [String] {
        controllers.compactMap { c in
            guard let chat = chats[c.record.id] else { return nil }
            let w = chat.window
            return "chat \(c.record.number) visible=\(w.isVisible) minimized=\(w.isMiniaturized) fullScreen=\(chat.isFullScreen) key=\(w.isKeyWindow) inWindowsMenu=\(!w.isExcludedFromWindowsMenu)"
        }
    }

    /// omochi://window 用（自動化のときだけ）：ボタンやキーを押したのと同じ操作
    func debugChatWindow(_ c: JellyController, _ action: String) {
        guard let chat = chats[c.record.id] else { return }
        switch action {
        case "minimize": chat.window.miniaturize(nil)
        case "fullscreen": chat.window.toggleFullScreen(nil)
        case "esc": chat.closeAndReturn()
        case "close": chat.window.performClose(nil)
        default: break
        }
    }

    /// Dock のアイコンを押したとき：しまったチャットしか無ければ、最後に使ったものを戻す。出ているチャットがあれば前に出す。
    /// チャットが 1 つも無ければ false
    @discardableResult
    func reopenChats() -> Bool {
        let open = chats.values.filter { $0.isVisible }
        guard !open.isEmpty else { return false }
        chatWindowVisibilityChanged(showing: true)
        NSApp.activate(ignoringOtherApps: true)
        if let front = open.filter({ $0.window.isVisible }).max(by: { $0.lastActive < $1.lastActive }) {
            front.window.makeKeyAndOrderFront(nil)
        } else if let last = open.max(by: { $0.lastActive < $1.lastActive }) {
            last.window.deminiaturize(nil)
            last.window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// 過去の Claude Code セッション（プロジェクト）をおもちで呼び出す
    func resumeSession(_ info: ClaudeSessionInfo) {
        if let c = controllers.first(where: { runtimes[$0.record.id]?.sessionID == info.id }) {
            if c.record.hidden || settings.allHidden { setHidden(c, false); if settings.allHidden { setAllHidden(false) } }
            openChat(for: c)
            return
        }
        if settings.allHidden { setAllHidden(false) }
        let c = addController(makeRecord())
        runtimes[c.record.id]?.bind(to: info)
        c.setState(.completed)
        c.show(animated: true)
        save()
        onChange?()
        openChat(for: c)
    }

    // MARK: 聞き取り（システムの音 → 文字起こし）

    func isListening(_ c: JellyController) -> Bool { listener?.agent == c.record.id }

    /// 聞き取り中の表示（経過時間と最後の文）
    func listeningStatus(_ c: JellyController) -> String? {
        guard #available(macOS 26.0, *), listener?.agent == c.record.id, let t = listener?.object as? AudioTranscriber else { return nil }
        let s = Int(Date().timeIntervalSince(t.startedAt))
        let last = t.partial.isEmpty ? (t.lines.last.map { String($0.dropFirst(8)) } ?? "") : t.partial
        return L("🎧 聞き取り中 %@", String(format: "%d:%02d", s / 60, s % 60)) + (last.isEmpty ? "" : " — " + String(last.suffix(40)))
    }

    /// 聞き取りの開始・停止。止めたら文字起こしをチャットの添付にする（「議事録にして」「英訳して」などと続けて頼める）
    func toggleListening(_ c: JellyController) {
        guard #available(macOS 26.0, *) else {
            alert(L("聞き取りには macOS 26 以降が必要です"), "")
            return
        }
        if let cur = listener, let t = cur.object as? AudioTranscriber {
            listener = nil
            let agent = cur.agent
            Task { @MainActor in
                await t.stop()
                self.lastTranscript[agent] = t.fileURL
                if let ctl = self.controllers.first(where: { $0.record.id == agent }) {
                    self.openChat(for: ctl)
                    self.chats[agent]?.addAttachments([t.fileURL])
                    self.chats[agent]?.setInputHint(L("文字起こしを添付しました。例:「議事録にまとめて」「英語に翻訳して」「要点と ToDo を出して」"))
                }
                self.onChange?()
            }
            if agent == c.record.id { return }
        }
        guard let rt = runtimes[c.record.id] else { return }
        let t = AudioTranscriber(dir: rt.dir.appendingPathComponent("transcripts", isDirectory: true))
        listener = (c.record.id, t)
        let id = c.record.id
        t.onUpdate = { [weak self] in self?.chats[id]?.refresh() }
        chats[id]?.refresh()
        Task { @MainActor in
            do {
                try await t.start()
                self.lastTranscript[id] = t.fileURL
            } catch {
                if self.listener?.agent == id { self.listener = nil }
                self.alert(L("聞き取りを始められませんでした"), error.localizedDescription)
            }
            self.chats[id]?.refresh()
            self.onChange?()
        }
    }

    /// 文字起こしの中身（エージェントの read_transcript 用）
    func transcriptText(for id: UUID, sinceLine: Int) -> (path: String, lines: [String], live: Bool)? {
        guard let url = lastTranscript[id], let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = s.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
        return (url.path, Array(lines.dropFirst(max(0, sinceLine))), listener?.agent == id)
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        ActiveSpace.runModal(a)
    }

    /// 「過去のセッション」の一覧から外す / 戻す（Claude Code のセッションファイルには触れない）
    func setArchived(_ sessionID: String, _ on: Bool) {
        updateSettings { s in
            s.archivedSessions.removeAll { $0 == sessionID }
            if on { s.archivedSessions.append(sessionID) }
        }
    }

    /// ファイルをおもちに落としたとき：チャットを開いて添付に加える（大福にするかは filesDropped で聞く）
    func attachFiles(_ urls: [URL], to c: JellyController) {
        openChat(for: c)
        chats[c.record.id]?.addAttachments(urls)
    }

    /// そのセッションを使っているおもちの番号（メニュー表示用）
    func agentNumber(forSession id: String) -> Int? {
        controllers.first { runtimes[$0.record.id]?.sessionID == id }?.record.number
    }

    /// 作業中のおもちを消すときの確認の吹き出し（おもちごと）
    private var removeBubbles: [UUID: WatchBubble] = [:]

    /// 長押しで消す。実行中なら、勝手にキャンセルせず確認する。
    /// 確認はおもちの上の吹き出しで聞く（どのスペース・ほかのアプリのフル画面の上にも出て、入力先を奪わない）。
    /// モーダルの確認の窓だと、ほかのアプリのフル画面を見ているときなどに見えないスペースに出て、
    /// 答えるまでおもちを押しても何も起きず、アプリの終了もできなくなっていた
    func requestRemove(_ c: JellyController) {
        DevJournal.log("remove-request", ["agent": c.record.number, "running": runtimes[c.record.id]?.isRunning ?? false])
        guard let rt = runtimes[c.record.id], rt.isRunning else {
            remove(c)
            return
        }
        c.avatar.pressCancelled()
        let id = c.record.id
        guard removeBubbles[id] == nil else { return }
        let finish: (String) -> Void = { [weak self, weak c] choice in
            guard let self, self.removeBubbles.removeValue(forKey: id) != nil else { return }
            guard let c, self.controllers.contains(where: { $0 === c }) else { return }
            AppLog.write("remove confirm: agent \(c.record.number) \(choice)")
            switch choice {
            case "keep":
                // 動いている作業は remove が最後まで持っておく（終わったら手放す）
                self.remove(c)
            case "cancel":
                self.runtimes[id]?.cancel()
                self.remove(c)
            default:
                break
            }
        }
        let text = WatchBubble.Text(title: L("%@ はまだ作業中です", c.record.title),
                                    detail: L("おもちを消しても、作業はバックグラウンドで最後まで続けられます。結果は履歴（ログ）に残ります。"),
                                    show: L("作業は続けて、おもちだけ消す"), closeTip: "", ignore: L("作業をキャンセルして消す"),
                                    note: nil, detailLines: 4, closeTitle: L("やめる"), stacked: true)
        // 答えないまま 60 秒たったら「やめる」と同じ（消さない）
        let b = WatchBubble(text, accent: c.record.color.nsColor, near: c.panel.frame, autoClose: 60,
                            onShow: { finish("keep") }, onDismiss: { finish("dismiss") }, onIgnoreApp: { finish("cancel") })
        removeBubbles[id] = b
        b.present()
        AppLog.write("remove confirm: agent \(c.record.number) asked (still working)")
    }

    /// おもちを削除する。
    /// Phase 2: 実行中タスクがある場合はキャンセルするか継続するかを確認し、勝手にキャンセルしない。
    func remove(_ c: JellyController) {
        DevJournal.log("remove", ["agent": c.record.number, "running": runtimes[c.record.id]?.isRunning ?? false,
                                  "turns": runtimes[c.record.id]?.turns.count ?? 0, "org": c.record.orgSpawned ?? false,
                                  "clone": c.record.forkOf != nil, "total": controllers.count - 1])
        removeBubbles.removeValue(forKey: c.record.id)?.close()
        mochiRemoved(c.record.id)
        team?.removeAgent(c.record.id)
        queues.agentRemoved(c.record.id)
        if let chat = chats.removeValue(forKey: c.record.id) {
            chat.dismiss()
            chatWindowVisibilityChanged()
        }
        if let rt = runtimes.removeValue(forKey: c.record.id) {
            if rt.isRunning {
                // 実行中のまま参照を手放すと claude が止められなくなるので、終わるまで持っておく（終了時にも止める）
                if !detached.contains(where: { $0 === rt }) {
                    rt.onUpdate = nil
                    detached.append(rt)
                    rt.onState = { [weak self, weak rt] s in
                        if s.isTerminal || s == .error { self?.detached.removeAll { $0 === rt } }
                    }
                }
            } else {
                rt.onState = nil
                rt.onUpdate = nil
                rt.deleteScratchFiles()
            }
        }
        controllers.removeAll { $0 === c }
        c.despawn {}
        team?.refresh()
        save()
        onChange?()
    }

    // MARK: 名前

    /// 他のおもちと重ならない名前（重なれば「名前 2」「名前 3」…）
    func uniqueName(_ base: String, excluding me: JellyController? = nil) -> String {
        let used = Set(controllers.filter { $0 !== me }.map { $0.record.title.lowercased() })
        if !used.contains(base.lowercased()) { return base }
        var i = 2
        while used.contains("\(base) \(i)".lowercased()) { i += 1 }
        return "\(base) \(i)"
    }

    /// 名前を変える。空なら「Agent N」に戻す。問題があればその理由を返す
    @discardableResult
    func rename(_ c: JellyController, to raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.count > 24 { return L("名前は 24 文字までです") }
        if !n.isEmpty, let other = controllers.first(where: { $0 !== c && $0.record.title.lowercased() == n.lowercased() }) {
            return L("「%@」は %@ のおもちが使っています", n, other.record.color.name)
        }
        c.update { $0.name = n.isEmpty ? nil : n }
        c.panel.title = c.record.title
        chats[c.record.id]?.refresh()
        team?.refresh()
        onChange?()
        return nil
    }

    func promptRename(_ c: JellyController) {
        let a = NSAlert()
        a.messageText = L("%@（%@）の名前", c.record.title, c.record.color.name)
        a.informativeText = L("エージェント同士はこの名前で呼び合います。空にすると「Agent %ld」に戻ります。", c.record.number)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = c.record.name ?? ""
        f.placeholderString = "Agent \(c.record.number)"
        a.accessoryView = f
        a.addButton(withTitle: L("変更"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = f
        guard ActiveSpace.runModal(a) == .alertFirstButtonReturn else { return }
        if let err = rename(c, to: f.stringValue) {
            let e = NSAlert()
            e.messageText = L("名前を変えられませんでした")
            e.informativeText = err
            ActiveSpace.runModal(e)
        }
    }

    // MARK: チーム

    /// エージェントが create_teammate で仲間を作る：呼んだおもちの隣に出し、作業フォルダ・モデル・強さを引き継ぐ
    func spawnTeammate(near parent: JellyController, name: String, orgSpawned: Bool = false, engine: AgentEngine? = nil) -> JellyController? {
        guard controllers.count < TeamCoordinator.maxAgents else { return nil }
        if settings.allHidden { setAllHidden(false) }
        if parent.record.hidden { setHidden(parent, false) }
        var r = makeRecord()
        r.name = name
        if orgSpawned { r.orgSpawned = true }
        r.parentID = parent.record.id
        r.depth = (parent.record.depth ?? 0) + 1
        r.origin = adjacentOrigin(near: parent)
        let c = addController(r)
        DevJournal.log("spawn-teammate", ["agent": c.record.number, "parent": parent.record.number, "org": orgSpawned,
                                          "engine": (engine ?? runtimes[parent.record.id]?.effectiveEngine ?? settings.engine).rawValue])
        if let prt = runtimes[parent.record.id], let rt = runtimes[c.record.id] {
            // 仲間は、指定がなければ作った側と同じ AI で動く（AI ごとの得意なことで分担するときは engine を指定）
            rt.changeEngine(engine ?? prt.effectiveEngine)
            rt.changeFolder(prt.cwd)
            // モデル・強さは AI ごとに名前が違うので、同じ AI のときだけ受け継ぐ（Claude の「max」を Codex に渡さない）
            if rt.effectiveEngine == prt.effectiveEngine {
                rt.model = prt.model
                rt.effort = prt.effort
            }
        }
        c.show(animated: true)
        save()
        onChange?()
        return c
    }

    /// 隣（体 1 つ分）の空いている場所。左 → 斜め → 上下の順に探す
    func adjacentOrigin(near p: JellyController) -> NSPoint {
        let L = layout
        let size = L.size
        let o = p.panel.frame.origin
        // 線と受け渡しの光が見えるよう、体 1.5 個ぶん離して置く
        let sx = L.stepX * 1.5, sy = L.stepY * 1.35
        let offsets: [(CGFloat, CGFloat)] = [(-sx, 0), (-sx * 0.6, -sy), (-sx * 0.6, sy), (0, -sy), (0, sy),
                                             (-sx * 1.6, -sy), (-sx * 1.6, sy), (-2 * sx, 0), (sx * 0.5, -sy), (sx * 0.5, sy)]
        let vf = (p.panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let others = controllers.filter { $0 !== p && !$0.record.hidden }.map { $0.panel.frame.origin } + [o]
        for (dx, dy) in offsets {
            let c = NSPoint(x: o.x + dx, y: o.y + dy)
            let core = NSRect(origin: c, size: size).insetBy(dx: size.width * 0.2, dy: size.height * 0.2)
            guard vf.contains(core) else { continue }
            if others.contains(where: { hypot($0.x - c.x, $0.y - c.y) < size.width * 0.7 }) { continue }
            return c
        }
        return freeSlotOrigin(excluding: nil)
    }

    func jellyDragBegan(_ c: JellyController, origin: NSPoint) { team?.jellyDragBegan(c, origin: origin) }
    func jellyDragged(_ c: JellyController, mods: NSEvent.ModifierFlags) { team?.jellyDragged(c, mods: mods) }
    func jellyDropped(_ c: JellyController, mods: NSEvent.ModifierFlags) { team?.jellyDropped(c, mods: mods) }

    /// つながりが変わった：開いているチャットの「チーム」表示を更新
    func teamChanged() {
        for chat in chats.values where chat.isVisible { chat.refresh() }
    }

    /// デモ録画用：ドラッグと同じ経路で動かして、最後に置く（隣ならつながる）。mods で ⇧ / ⌥ を押した扱いにできる
    /// hold は置く前に止める秒数（重ねる・頭に載せるは TeamCoordinator.armDelay より長く止めると、くっつく・載る）
    func demoDrag(_ c: JellyController, by d: CGVector, duration: Double = 0.8, mods: NSEvent.ModifierFlags = [], hold: Double = 0.5) {
        let start = c.panel.frame.origin
        let steps = 24
        c.avatar.dragBegan()
        team?.jellyDragBegan(c, origin: start)
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) { [weak self, weak c] in
                guard let self, let c else { return }
                let t = Double(i) / Double(steps)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                c.panel.setFrameOrigin(NSPoint(x: start.x + d.dx * e, y: start.y + d.dy * e))
                self.jellyDragged(c, mods: mods)
                if i == steps {
                    // 置く前に一瞬止めて「離すとつながる」を見せる
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, hold)) { [weak self, weak c] in
                        guard let self, let c else { return }
                        c.avatar.dragEnded()
                        c.update { $0.origin = c.panel.frame.origin }
                        self.jellyDropped(c, mods: mods)
                    }
                }
            }
        }
    }

    func controller(number: Int) -> JellyController? { controllers.first { $0.record.number == number } }

    // MARK: 表示・非表示（非表示でもバックグラウンド処理は止めない）

    func setAllHidden(_ hidden: Bool) {
        settings.allHidden = hidden
        store.save(settings)
        for c in controllers where !c.record.hidden {
            hidden ? c.hide() : c.show(animated: true)
        }
        team?.refresh()
        onChange?()
    }

    func toggleAllHidden() { setAllHidden(!settings.allHidden) }

    func setHidden(_ c: JellyController, _ hidden: Bool) {
        c.update { $0.hidden = hidden }
        if hidden { c.hide() } else if !settings.allHidden { c.show(animated: true) }
        team?.refresh()
        onChange?()
    }

    func resetPosition(_ c: JellyController) {
        c.moveTo(freeSlotOrigin(excluding: c), persist: true)
    }

    func arrangeAll() {
        var placed: [JellyController] = []
        for c in controllers {
            let o = freeSlotOrigin(excluding: c, among: placed)
            c.moveTo(o, persist: true)
            placed.append(c)
        }
    }

    // MARK: 設定

    func setScale(_ s: Double) {
        guard abs(s - settings.jellyScale) > 0.001 else { return }
        settings.jellyScale = s
        store.save(settings)
        rebuildControllers()
    }

    func setFrameRates(max: Int, calm: Int) {
        settings.maxFPS = max
        settings.calmFPS = calm
        store.save(settings)
        controllers.forEach { $0.avatar.setFrameRates(max: max, calm: calm) }
        onChange?()
    }

    func setStyle(_ style: AvatarStyle) {
        guard style != settings.avatarStyle else { return }
        DevJournal.log("style", ["to": style.rawValue])
        settings.avatarStyle = style
        store.save(settings)
        rebuildControllers()
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        store.save(settings)
        onChange?()
    }

    /// サイズ変更時：おもちの上端中央を基準に作り直す
    private func rebuildControllers() {
        let old = controllers
        controllers = []
        for c in old {
            var r = c.record
            let f = c.panel.frame
            let size = windowSize
            r.origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height)
            c.close()
            let n = addController(r)
            chats[r.id]?.attach(jelly: n)
            if !settings.allHidden && !r.hidden { n.show(animated: true) }
        }
        refreshAllLooks()
        team?.refresh()
        save()
        onChange?()
    }

    // MARK: 配置

    /// 画面右端から縦に並べ、互い違いにずらした「群れ」の配置スロット
    private func slotOrigins(on screen: NSScreen) -> [NSPoint] {
        let vf = screen.visibleFrame
        let L = layout
        let size = L.size
        let stepY = L.stepY
        let stepX = L.stepX
        let rows = max(1, SafeNumber.int((vf.height * 0.90 - size.height) / stepY, in: 0...200) + 1)
        var out: [NSPoint] = []
        for col in 0..<8 {
            for row in 0..<rows {
                let stagger: CGFloat = row % 2 == 1 ? L.stagger : 0
                let x = vf.maxX - size.width + L.edgeOverhang - CGFloat(col) * stepX + stagger
                // 最上段はアプリのツールバーと重なりやすいので、少し下から並べる
                let y = vf.maxY - size.height - vf.height * 0.10 - CGFloat(row) * stepY
                out.append(NSPoint(x: x, y: y))
            }
        }
        return out
    }

    func freeSlotOrigin(excluding me: JellyController?, among: [JellyController]? = nil) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return .zero }
        let others = (among ?? controllers).filter { $0 !== me && !$0.record.hidden }.map { $0.panel.frame.origin }
        let minDist = windowSize.width * 0.45
        let slots = slotOrigins(on: screen)
        for s in slots where !others.contains(where: { hypot($0.x - s.x, $0.y - s.y) < minDist }) {
            return s
        }
        return slots[0]
    }

    /// ディスプレイ構成が変わっておもちが画面外に出たら、空きスロットへ戻す
    func ensureOnScreen() {
        for c in controllers {
            let f = c.panel.frame
            let core = f.insetBy(dx: f.width * 0.3, dy: f.height * 0.3)
            if !NSScreen.screens.contains(where: { $0.frame.intersects(core) }) {
                c.moveTo(freeSlotOrigin(excluding: c), persist: true)
            }
        }
    }

    // MARK: ポインタ追跡（透明部分はクリックを素通しさせる）

    private func startPointerTracking() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollPointer() }
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    private func pollPointer() {
        // 約 2 秒ごとに、おもちと糸がちゃんと画面に出ているかを確かめる（出ていなければ出し直す）
        windowCheckTicks += 1
        if windowCheckTicks >= 60 {
            windowCheckTicks = 0
            reassertWindows("watch")
        }
        // ドラッグ中に ⇧ / ⌥ を押した・離したら、マウスが止まっていても表示を切り替える
        if let d = controllers.first(where: { $0.isBeingDragged }) {
            let mods = NSEvent.modifierFlags.intersection([.shift, .option])
            if mods != lastDragMods { lastDragMods = mods; team?.jellyDragged(d, mods: mods) }
        } else {
            lastDragMods = []
        }
        let p = NSEvent.mouseLocation
        if p == lastPointer {
            // ポインタが止まっていても、おもち側が漂って位置が変わるので時々は再判定する
            pointerIdleTicks += 1
            if pointerIdleTicks < 10 { return }
        }
        pointerIdleTicks = 0
        lastPointer = p
        var hovered: JellyController?
        for c in controllers.reversed() {
            if c.updatePointer(p, allowed: hovered == nil) { hovered = c }
        }
        team?.pointerMoved(p, over: hovered)
    }

    // MARK: 窓の見張り（おもちと糸が、いつ・どのスペースでも出ているように）

    /// 切り替えの動きが終わるのを待ってから確かめる（すぐと、少しあとの 2 回）
    func reassertWindowsSoon(_ reason: String) {
        for delay in [0.35, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reassertWindows(reason) }
        }
    }

    /// 出ているはずのおもち・糸の窓が画面に出ていなければ、前に出し直して描き直す。
    /// 画面がロック中・スリープ中・ミッションコントロール中などは、どの窓も画面に出ていないので何もしない
    /// （出ているおもちが 1 体もいなければ、比べる基準が無いので待つ）
    @discardableResult
    func reassertWindows(_ reason: String, onScreen: (NSWindow) -> Bool = WindowProbe.isOnScreen) -> [String] {
        guard !settings.allHidden else { return [] }
        let shown = controllers.filter { $0.isVisible }
        guard !shown.isEmpty else { return [] }
        let states = shown.map { ($0, $0.panel.isVisible && onScreen($0.panel)) }
        // ほかのおもちも出ていないなら、画面そのものが見えていない（ロック・スリープ・切り替えの途中）
        guard states.contains(where: { $0.1 }) else { return [] }
        var fixed: [String] = []
        let lost = Set(states.filter { !$0.1 }.map(\.0.record.id))
        defer { lostMochi = lost }
        for (c, ok) in states where !ok {
            c.panel.orderFrontRegardless()
            if !lostMochi.contains(c.record.id) { fixed.append("mochi \(c.record.number)") }
        }
        // 鏡餅は上の段が手前
        if !lost.isEmpty {
            for c in controllers where controllers.contains(where: { $0.record.leaderID == c.record.id }) && c.isVisible {
                c.panel.orderFrontRegardless()
            }
        }
        if let n = team?.overlay.reassert(onScreen: onScreen), n > 0 {
            fixed.append("strings ×\(n)")
            team?.refresh()
        }
        if !fixed.isEmpty, Date().timeIntervalSince(lastWindowFixLog) > 10 {
            lastWindowFixLog = Date()
            AppLog.write("windows re-shown (\(reason)): \(fixed.joined(separator: ", "))")
            DevJournal.log("windows-reshown", ["reason": reason, "count": fixed.count])
        }
        return fixed
    }

    // MARK: イベント

    func jellyClicked(_ c: JellyController) {
        DevJournal.log("tap", ["agent": c.record.number, "state": c.record.state.rawValue])
        openChat(for: c)
        onChange?()
    }

    /// アプリ終了時：実行中のエージェントを中断して記録を残す
    /// 「🔐 権限」の画面。done は permissions.sh から（grant = 古い許可を消し終わった）
    private var permissionsWindow: PermissionsWindowController?
    func showPermissions(done: String? = nil) {
        let w = permissionsWindow ?? PermissionsWindowController(manager: self)
        permissionsWindow = w
        if done == "grant" { w.grantFinished() } else { w.show() }
    }

    // MARK: - コネクタ（カレンダー・リマインダー・メール）

    private var connectorsWindow: ConnectorsWindowController?
    func showConnectors() {
        let w = connectorsWindow ?? ConnectorsWindowController(manager: self)
        connectorsWindow = w
        w.show()
    }

    func updateConnectors(_ change: (inout ConnectorSettings) -> Void) {
        updateSettings { change(&$0.connectors) }
        AppLog.write("connectors: \(ConnectorKind.allCases.map { "\($0.rawValue)=\(ConnectorPolicy.summary(settings.connectors[$0]))" }.joined(separator: " | "))")
    }

    /// ワンタッチ設定（ボタン 1 つで、すべてのコネクタの決まりをまとめて変える）
    func applyConnectorPreset(_ p: ConnectorPreset) {
        updateConnectors { $0 = p.settings }
        DispatchQueue.main.async { [weak self] in self?.connectorsWindow?.rebuild() }
    }

    /// 書き込みの確認：おもちの横に吹き出しを出し、押されたら true。✕・5 分たっても押されなければ false。
    /// 入力先は奪わない（キーにならないパネル）
    private var connectorBubbles: [UUID: WatchBubble] = [:]
    func confirmConnector(for c: JellyController, action: MacConnectors.Action, engine: AgentEngine, completion: @escaping (Bool) -> Void) {
        let key = UUID()
        var answered = false
        let finish: (Bool) -> Void = { [weak self] ok in
            guard !answered else { return }
            answered = true
            self?.connectorBubbles[key] = nil
            AppLog.write("connector confirm: agent \(c.record.number) \(ok ? "approved" : "declined")")
            completion(ok)
        }
        let text = WatchBubble.Text(title: action.title, detail: action.detail, show: action.confirm,
                                    closeTip: L("やめる（実行しない）"), ignore: "",
                                    note: L("%@（%@）からの依頼。押したときだけ実行します", c.record.title, engine.displayName),
                                    detailLines: 6, closeTitle: L("やめる"))
        let b = WatchBubble(text, accent: c.record.color.nsColor, near: c.panel.frame, autoClose: 300,
                            onShow: { finish(true) }, onDismiss: { finish(false) }, onIgnoreApp: { finish(false) })
        connectorBubbles[key] = b
        b.present()
    }

    /// デモの録画用（合言葉つきの自動化のときだけ）：コネクタの画面を前面化せずに出す・ボタンを押す・閉じる
    func debugConnectors(topLeft: NSPoint?, press: String?, close: Bool) {
        let w = connectorsWindow ?? ConnectorsWindowController(manager: self)
        connectorsWindow = w
        if close { w.window.orderOut(nil); return }
        if !w.window.isVisible { w.showForDemo(topLeft: topLeft) } else if let p = topLeft {
            w.window.setFrameTopLeftPoint(NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y))
        }
        if let id = press, !w.pressForDemo(id) { AppLog.write("connectors demo: no button \(id.prefix(40))") }
    }

    /// デモの録画用：書き込みの確認の吹き出しを見本の中身で出す（answer で「追加する」「やめる」を押す。何も書き込まない）
    private var demoConfirm: WatchBubble?
    func debugConnectorConfirm(_ c: JellyController?, answer: String?) {
        if let a = answer { demoConfirm?.pressForDemo(a == "yes"); return }
        guard let c else { return }
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()
        let detail = ["「" + L("打ち合わせ") + "」",
                      ConnectorDates.display(start, dateOnly: false) + "–" + MacConnectors.time(start.addingTimeInterval(3600)),
                      L("カレンダー: %@", L("仕事"))].joined(separator: "\n")
        let text = WatchBubble.Text(title: L("📅 予定を追加していい？"), detail: detail, show: L("追加する"),
                                    closeTip: L("やめる（実行しない）"), ignore: "",
                                    note: L("%@（%@）からの依頼。押したときだけ実行します", c.record.title, AgentEngine.claude.displayName),
                                    detailLines: 6, closeTitle: L("やめる"))
        let b = WatchBubble(text, accent: c.record.color.nsColor, near: c.panel.frame, autoClose: 60,
                            onShow: { [weak self] in self?.demoConfirm = nil }, onDismiss: { [weak self] in self?.demoConfirm = nil },
                            onIgnoreApp: { [weak self] in self?.demoConfirm = nil })
        demoConfirm = b
        b.present()
    }

    /// おもちごとのメニューに出す、そのおもちがいま使えるコネクタ
    func connectorSummary(for c: JellyController) -> String? {
        guard settings.connectors.anyEnabled, let rt = runtimes[c.record.id], let team else { return nil }
        let ks = ConnectorPolicy.kinds(team.connectorTools(c.record.id, rt))
        if ks.isEmpty { return L("🔌 コネクタ: このおもち（%@）には渡さない設定", rt.effectiveEngine.displayName) }
        return L("🔌 コネクタ: %@", ks.map { "\($0.0.icon)\($0.0.label)（\($0.writes ? ConnectorAccess.readWrite.shortLabel : ConnectorAccess.read.shortLabel)）" }.joined(separator: L("・")))
    }

    /// まとめて取り消す前に：すべてのおもちの PC 操作をオフにし、操作中なら止め、🎧 の聞き取りを止める
    func disableAllPrivileges() {
        if let d = DesktopControl.shared.driver { DesktopControl.shared.release(d) }
        for rt in runtimes.values where rt.pcControl { rt.pcControl = false }
        for rt in detached where rt.pcControl { rt.pcControl = false }
        if let cur = listener, let c = controllers.first(where: { $0.record.id == cur.agent }) { toggleListening(c) }
        stopAllWatching()
        for (_, chat) in chats { chat.refresh() }
        AppLog.write("privileges disabled (pc control off, listening stopped, watching stopped)")
    }

    /// 作業中のおもちがいるか（アップデートで入れ替える前に確かめる）
    var anyAgentBusy: Bool { runtimes.values.contains { $0.isRunning } || detached.contains { $0.isRunning } }

    func shutdown() {
        for rt in runtimes.values where rt.isRunning { rt.cancel() }
        for rt in detached where rt.isRunning { rt.cancel() }
        team?.shutdown()
        usage.flush()
        save()
    }

    func recordChanged() {
        scheduleSave()
        onChange?()
    }

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        store.save(controllers.map { $0.record })
        store.save(settings)
    }

    // MARK: メニュー

    func agentMenuItems(for c: JellyController, includeHeader: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let r = c.record
        if includeHeader {
            let h = NSMenuItem.header("\(r.title) · \(r.color.name) · \(r.state.label)")
            h.image = MenuImages.dot(r.color, state: r.state)
            items.append(h)
            items.append(.separator())
        }
        items.append(ClosureMenuItem(L("チャットを開く…")) { [weak self, weak c] in if let c { self?.openChat(for: c) } })
        if let cs = connectorSummary(for: c) {
            items.append(ClosureMenuItem(cs) { [weak self] in self?.showConnectors() })
        }
        items.append(ClosureMenuItem(L("名前を変える…")) { [weak self, weak c] in if let c { self?.promptRename(c) } })
        let watching = runtimes[r.id]?.watchScreen == true
        items.append(ClosureMenuItem(L("👀 見守る（エラーに気づいたら聞く）"), checked: watching) { [weak self, weak c] in
            if let c { self?.setWatching(c, !watching) }
        })
        if let team, settings.teamEnabled {
            // ドラッグしなくても、離れたおもちとつなげる
            let others = controllers.filter { $0 !== c && !$0.record.hidden && !team.isLinked(r.id, $0.record.id) }
            if !others.isEmpty {
                let li = NSMenuItem(title: L("つなぐ"), action: nil, keyEquivalent: "")
                let lm = NSMenu()
                lm.autoenablesItems = false
                for o in others {
                    let oid = o.record.id
                    let it = ClosureMenuItem(L("🔗 %@ とつなぐ", o.record.title), image: MenuImages.dot(o.record.color, state: o.record.state)) {
                        [weak team] in team?.link(r.id, oid)
                    }
                    it.isEnabled = team.canLink(r.id, oid)
                    if !it.isEnabled { it.toolTip = L("チームは %ld 体まで", TeamCoordinator.maxTeamSize) }
                    lm.addItem(it)
                }
                li.submenu = lm
                items.append(li)
            }
        }
        if let team, !team.neighbors(r.id).isEmpty {
            let li = NSMenuItem(title: L("つながり"), action: nil, keyEquivalent: "")
            let lm = NSMenu()
            lm.autoenablesItems = false
            if let p = team.pendingDescription(for: r.id) { lm.addItem(.header(p)) }
            for n in team.neighbors(r.id) {
                lm.addItem(ClosureMenuItem(L("✂︎ %@ とのつながりを切る", team.name(n))) { [weak team] in team?.unlink(r.id, n) })
            }
            lm.addItem(.separator())
            lm.addItem(ClosureMenuItem(L("すべてのつながりを切る")) { [weak team] in team?.unlinkAll(r.id) })
            li.submenu = lm
            items.append(li)
        }
        if let rt = runtimes[c.record.id], rt.isRunning {
            items.append(ClosureMenuItem(L("作業をキャンセル")) { [weak rt] in rt?.cancel() })
        }
        // お餅の性質（ちぎる・くっつく・鏡餅・串だんご・あんこ・温め直す）
        items.append(.separator())
        items += mochiMenuItems(for: c)
        items.append(.separator())
        let preview = NSMenuItem(title: L("状態プレビュー"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in AgentState.allCases {
            sub.addItem(ClosureMenuItem(L("%@（%@）", s.label, s.englishLabel), checked: r.state == s) { [weak c] in
                c?.setState(s)
            })
        }
        preview.submenu = sub
        items.append(preview)
        if r.hidden {
            items.append(ClosureMenuItem(L("表示する")) { [weak self, weak c] in if let c { self?.setHidden(c, false) } })
        } else {
            items.append(ClosureMenuItem(L("このおもちを隠す")) { [weak self, weak c] in if let c { self?.setHidden(c, true) } })
        }
        items.append(ClosureMenuItem(L("定位置に戻す")) { [weak self, weak c] in if let c { self?.resetPosition(c) } })
        items.append(.separator())
        items.append(ClosureMenuItem(L("このおもちを削除")) { [weak self, weak c] in if let c { self?.requestRemove(c) } })
        return items
    }

    func contextMenu(for c: JellyController) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        agentMenuItems(for: c, includeHeader: true).forEach { m.addItem($0) }
        return m
    }
}

// MARK: - 予約（PromptQueues）とのやりとり

extension JellyManager: PromptQueueHost {
    func queueAgentExists(_ id: UUID) -> Bool { runtimes[id] != nil && controllers.contains { $0.record.id == id } }
    func queueAgentRunning(_ id: UUID) -> Bool { runtimes[id]?.isRunning ?? false }
    func queueAgentName(_ id: UUID) -> String { controllers.first { $0.record.id == id }?.record.title ?? "?" }

    func queueSubmit(_ prompt: String, to id: UUID) -> QueueSubmitResult {
        guard let rt = runtimes[id] else { return .refused(L("送り先のおもちがいません")) }
        guard !rt.isRunning else { return .refused(L("作業中です")) }
        return rt.submit(prompt) ? .sent : .refused(rt.lastError)
    }

    func queueCancel(_ id: UUID) { runtimes[id]?.cancel() }

    /// 予約・串だんごで結果を次のおもちへ渡した：渡した側の色の塊が、串（または糸）をたどって届く
    func queueHandoff(from: UUID, to: UUID) {
        guard let a = controller(id: from), let b = controller(id: to), a.isVisible, b.isVisible else { return }
        team?.overlay.sendPackets(along: [a.anchorPoint, b.anchorPoint], color: a.record.color.nsColor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { b.avatar.absorb() }
    }

    func queuesChanged(_ agents: Set<UUID>) {
        for id in agents { chats[id]?.refresh() }
        onChange?()
    }

    /// 予約の送り先に選べるおもち（番号順）
    func queueAgents() -> [PromptQueueView.Agent] {
        controllers.sorted { $0.record.number < $1.record.number }.map {
            PromptQueueView.Agent(id: $0.record.id, title: $0.record.title, color: $0.record.color.nsColor)
        }
    }

    /// 自動化（omochi://queue）とテスト用：チャットの入力欄から送ったのと同じにする（作業中なら予約に足す）
    func submitFromChat(_ c: JellyController, text: String) {
        if chats[c.record.id] == nil {
            guard let rt = runtimes[c.record.id] else { return }
            let chat = AgentChatController(jelly: c, runtime: rt, size: NSSize(width: settings.chatWidth, height: settings.chatHeight))
            chat.manager = self
            chats[c.record.id] = chat
        }
        chats[c.record.id]?.submitText(text)
    }

    /// 自動化用：チャットの窓の中身を画像にする（画面に出さずに描く。会話の欄は WebKit なので写らないことがある）
    func snapshotChat(_ c: JellyController, to url: URL) -> Bool {
        guard let chat = chats[c.record.id], let v = chat.window.contentView else { return false }
        chat.refresh()
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// omochi://debug 用：予約の状態と、チャットに出している予約の文
    func debugQueueLines() -> [String] {
        var out = queues.debugLines()
        for c in controllers {
            // 指示の文はログに書かない（AppLog の決まり）。数と長さだけ
            if let t = chats[c.record.id]?.shownQueueTexts, !t.isEmpty { out.append("queue-view \(c.record.number): \(t.count) rows, chars \(t.map(\.count))") }
        }
        return out
    }
}
