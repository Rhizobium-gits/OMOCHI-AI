import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var manager: JellyManager!
    private var shortcuts: Shortcuts!
    private var statusBar: StatusBarController!
    private var pendingURLs: [URL] = []
    private var termSource: DispatchSourceSignal?
    private var urlThrottle = URLRoutes.Throttle()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 二重起動の防止（2つ目は即終了。URL は LaunchServices が既存側へ渡す）
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        // 同じデータフォルダを 2 つのプロセスで使わない（.app の外から起動した開発用ビルドでも効くようにロックファイルで）
        if !AppPaths.acquireInstanceLock() {
            AppLog.write("another instance is using \(AppPaths.dataDir.path); exiting")
            NSApp.terminate(nil)
            return
        }

        // kill（SIGTERM）で終えられたときも、普通の終了と同じく保存してエージェントを止める（scripts/install.sh の入れ替えなど）
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term

        // 自動化（デモ録画）用の合言葉を、URL を受け付ける前に用意する（普段は前回の残りを消すだけ）
        if URLRoutes.automationToken != nil { AppLog.write("automation mode: jellyfish:// with token accepted") }

        ShellEnvironment.shared.prefetch()
        DispatchQueue.global(qos: .utility).async { DataJanitor.cleanUp(dataDir: AppPaths.dataDir) }
        let store = Store()
        // 表示の言語は、メニューやウィンドウを作る前に決める
        L10n.setting = store.loadSettings().language
        // チャットはクラゲごとの窓なので、タブにまとめない（ウインドウ・表示のメニューにタブの項目を足させない）
        NSWindow.allowsAutomaticWindowTabbing = false
        installMainMenu()
        // 表示の言語を変えたら、メインメニュー（編集・ウインドウ）も作り直す
        NotificationCenter.default.addObserver(forName: JellyManager.languageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.installMainMenu()
        }
        // 初めての起動（データフォルダにまだクラゲの記録がない）なら、使い方と権限の案内を出す
        let firstLaunch = !store.hasSavedJellies
        manager = JellyManager(store: store)
        shortcuts = Shortcuts(manager: manager)
        statusBar = StatusBarController(manager: manager, shortcuts: shortcuts)
        manager.start()
        // アップデートの自動確認（メニューで間隔を選んだときだけ。既定は確認しない）
        UpdateSchedule.shared.start(manager: manager)
        let live = Set(manager.controllers.map(\.record.id))
        DispatchQueue.global(qos: .utility).async { DataJanitor.cleanUpRemovedAgents(dataDir: AppPaths.dataDir, live: live) }
        manager.prefetchBackend()
        shortcuts.registerAll()

        // 設定ファイルと実際の登録状態を合わせる（システム設定側で変更された場合も追従）
        if LoginItem.isAvailable {
            manager.updateSettings { $0.launchAtLogin = LoginItem.isEnabled }
        }

        pendingURLs.forEach(handle)
        pendingURLs.removeAll()

        AppLog.write("launch v\(AppInfo.version) (\(AppInfo.build)) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if firstLaunch {
            let key = (shortcuts.activeNewJelly ?? manager.settings.newJellyHotKey).display
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                AppInfo.showWelcome(manager: self.manager, newJellyKey: key)
            }
        }
    }

    /// チャット欄で ⌘C / ⌘V / ⌘A / ⌘Z、ウィンドウの ⌘W / ⌘M / ⌃⌘F が効くようにメインメニューを用意する。
    /// 並びと名前は Apple の HIG（The menu bar）と macOS のアプリに合わせる：
    /// 閉じるは「ファイル」、フルスクリーンは「表示」、しまう・拡大／縮小・すべてを手前に移動と窓の一覧は「ウインドウ」
    func installMainMenu() {
        let main = NSMenu()
        @discardableResult
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = m
            main.addItem(it)
            return m
        }
        func item(_ t: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let about = NSMenuItem(title: L("Jellyfish AI について"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        sub("Jellyfish AI", [
            about,
            .separator(),
            item(L("Jellyfish AI を隠す"), #selector(NSApplication.hide(_:)), "h"),
            item(L("ほかを隠す"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("すべてを表示"), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item(L("Jellyfish AI を終了"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub(L("ファイル"), [
            item(L("閉じる"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        sub(L("編集"), [
            item(L("取り消す"), Selector(("undo:")), "z"),
            item(L("やり直す"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("カット"), #selector(NSText.cut(_:)), "x"),
            item(L("コピー"), #selector(NSText.copy(_:)), "c"),
            item(L("ペースト"), #selector(NSText.paste(_:)), "v"),
            item(L("すべてを選択"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            // Mac の音声入力（入力欄で話すと文字になる）
            item(L("音声入力を開始"), Selector(("startDictation:")), ""),
        ])
        // AppKit の toggleFullScreen: のままだと、題名が開発言語（日本語）の「フルスクリーンにする」などに書き換わるので、
        // アプリの言語で「フルスクリーンにする／解除」と出すために自分で受けて前面の窓に渡す
        let fullScreen = item(L("フルスクリーンにする"), #selector(toggleFullScreenOfFrontWindow(_:)), "f", [.command, .control])
        fullScreen.target = self
        sub(L("表示"), [fullScreen])
        let windowMenu = sub(L("ウインドウ"), [
            item(L("しまう"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("拡大／縮小"), #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item(L("すべてを手前に移動"), #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        NSApp.mainMenu = main
        // 開いているチャットの一覧を AppKit がここに足す（しまったチャットもここから戻せる）
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showAbout() { AppInfo.showAbout() }

    /// 表示 › フルスクリーンにする／解除（⌃⌘F）
    @objc func toggleFullScreenOfFrontWindow(_ sender: Any?) {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleFullScreenOfFrontWindow(_:)) else { return true }
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow, w.collectionBehavior.contains(.fullScreenPrimary) else {
            menuItem.title = L("フルスクリーンにする")
            return false
        }
        menuItem.title = w.styleMask.contains(.fullScreen) ? L("フルスクリーンを解除") : L("フルスクリーンにする")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.shutdown()
    }

    /// 動いている最中に、アプリのアイコン（アプリケーションフォルダ・Spotlight・Dock・Launchpad）からもう一度開いたとき。
    /// 隠していたクラゲを出す。1 体もいなければ新しいクラゲを出して入力欄を開く
    /// しまったチャットがあれば戻す（Dock のアイコンを押すと、しまった窓が戻る Apple のアプリと同じ）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let manager else { return false }
        let reopened = manager.reopenChats()
        if manager.settings.allHidden {
            manager.setAllHidden(false)
        } else if manager.controllers.isEmpty && !reopened {
            _ = manager.spawn()
        }
        return false
    }

    /// jellyfish:// URL スキーム（ショートカット.app・Raycast 等からの操作と、自動テスト・デモ録画用）
    /// 外から誰でも呼べる（Web ページのリンクからも開ける）ので、普段は URLRoutes.publicRoutes だけ受け付ける
    /// （続けざまの呼び出しは間引き、新しいクラゲは上限まで）。
    /// 指示の送信・PC 操作の許可・作業フォルダの変更・削除などは、環境変数 JELLYFISH_AUTOMATION=1 を付けて
    /// 起動し（scripts/demo/record.sh）、データフォルダの automation.token の合言葉を token=… で付けたときだけ動く
    ///   jellyfish://new[?chat=0&cwd=~/dir]    新しいクラゲ（chat=0 で入力欄を開かない、cwd で作業フォルダ）
    ///   jellyfish://type?agent=2&text=...     入力欄に 1 文字ずつ打ち込んで送信（デモ録画用、cps=打鍵/秒）
    ///   jellyfish://press?agent=2             長押しと同じ動作（デモ録画用）
    ///   jellyfish://rename?agent=2&name=調査係  名前を変える（空で Agent N に戻す）
    ///   jellyfish://link?a=2&b=3 | unlink     2 体をつなぐ / 切る
    ///   jellyfish://move?agent=2&dx=-120&dy=40[&mods=shift|option&t=0.8]  ドラッグして置く（デモ録画用）
    ///   jellyfish://toggle | show | hide      全体の表示切替
    ///   jellyfish://arrange                   右端に並べ直す
    ///   jellyfish://renumber                  番号を 1 から振り直す
    ///   jellyfish://state?agent=2&s=working   状態を設定（Phase 1 ではプレビュー用）
    ///   jellyfish://remove?agent=2            削除
    ///   jellyfish://scale?v=1.25              大きさ
    ///   jellyfish://style?v=pixel|realistic   見た目
    ///   jellyfish://login?on=1|0              ログイン時の自動起動
    ///   jellyfish://debug                     各エージェント・アプリ（Dock に出ているか・メニュー）・チャットの窓の状態を app.log へ
    ///   jellyfish://window?agent=2&do=minimize|fullscreen|esc|close  チャットの窓の操作（テスト用）
    func application(_ application: NSApplication, open urls: [URL]) {
        if manager == nil { pendingURLs.append(contentsOf: urls); return }
        urls.forEach(handle)
    }

    private func handle(_ url: URL) {
        let host = String((url.host ?? "").prefix(32))
        guard URLRoutes.allowed(url, automationToken: URLRoutes.automationToken) else {
            if url.scheme == "jellyfish" { AppLog.write("url refused: \(host)（公開以外の操作は JELLYFISH_AUTOMATION=1 と合言葉が必要）") }
            return
        }
        let automation = URLRoutes.isAutomation(url, token: URLRoutes.automationToken)
        if !automation {
            guard urlThrottle.allow(host.lowercased()) else { AppLog.write("url throttled: \(host)"); return }
            if host.lowercased() == "new", manager.controllers.count >= TeamCoordinator.maxAgents {
                AppLog.write("url refused: new（クラゲが上限の \(TeamCoordinator.maxAgents) 体）")
                return
            }
        }
        if url.host != "debug" { AppLog.write("url: \(host)") }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }
        let agent = param("agent").flatMap(Int.init).flatMap { manager.controller(number: $0) }
        switch url.host ?? "" {
        case "new":
            // new?chat=0 で入力欄を開かない、new?cwd=~/foo で作業フォルダを指定（デモ・テスト用）
            // 外のアプリ・Web ページからのときは、チャットを出してもキーボードの入力先は奪わない
            let c = manager.spawn(openChat: param("chat") != "0", activate: automation)
            if let p = param("cwd"), let rt = manager.runtime(for: c) {
                rt.changeFolder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
            }
        case "type":
            // テスト用：jellyfish://type?agent=2&text=...&cps=14 で入力欄に打ち込んでから送信
            if let c = agent, let text = param("text") {
                manager.typePrompt(text, into: c, cps: param("cps").flatMap(Double.init) ?? 14, quick: param("quick") == "1")
            }
        case "press":
            if let c = agent { c.simulateLongPress() }
        case "rename":
            if let c = agent { let err = manager.rename(c, to: param("name") ?? ""); AppLog.write("rename -> \(err ?? "ok")") }
        case "link", "unlink":
            // jellyfish://link?a=2&b=3 でつなぐ / unlink で切る
            if let a = param("a").flatMap(Int.init).flatMap({ manager.controller(number: $0) }),
               let b = param("b").flatMap(Int.init).flatMap({ manager.controller(number: $0) }) {
                if url.host == "link" { manager.team?.link(a.record.id, b.record.id) }
                else if param("scissors") == "1" { manager.team?.cutWithScissors(a.record.id, b.record.id) }
                else { manager.team?.unlink(a.record.id, b.record.id) }
            }
        case "pc":
            // テスト用：jellyfish://pc?agent=2&on=1 で PC 操作を許可 / 0 で取り消す
            if let c = agent, let rt = manager.runtime(for: c) { rt.pcControl = param("on") == "1" }
        case "folder":
            if let c = agent, let p = param("path"), let rt = manager.runtime(for: c) {
                rt.changeFolder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
            }
        case "move":
            // デモ録画用：jellyfish://move?agent=2&dx=-120&dy=40 でドラッグしたように動かして置く
            // mods=shift でチームごと、mods=option で切り離し
            if let c = agent {
                var mods: NSEvent.ModifierFlags = []
                let m = param("mods") ?? ""
                if m.contains("shift") { mods.insert(.shift) }
                if m.contains("option") { mods.insert(.option) }
                manager.demoDrag(c, by: CGVector(dx: param("dx").flatMap(Double.init) ?? 0, dy: param("dy").flatMap(Double.init) ?? 0),
                                 duration: param("t").flatMap(Double.init) ?? 0.8, mods: mods)
            }
        case "toggle": manager.toggleAllHidden()
        case "show": manager.setAllHidden(false)
        case "hide": manager.setAllHidden(true)
        case "arrange": manager.arrangeAll()
        case "renumber": manager.renumber()
        case "state":
            if let c = agent, let s = param("s").flatMap(AgentState.init(rawValue:)) { c.setState(s) }
        case "remove":
            if let c = agent { manager.remove(c) }
        case "prompt":
            // テスト用：jellyfish://prompt?agent=2&text=... で指示を送る
            if let c = agent, let text = param("text"), let rt = manager.runtime(for: c) {
                let ok = rt.submit(text)
                AppLog.write("prompt submit agent=\(c.record.number) ok=\(ok) running=\(rt.isRunning)")
            } else {
                AppLog.write("prompt: agent/text/runtime missing agent=\(agent?.record.number ?? -1)")
            }
        case "queue":
            // テスト用：jellyfish://queue?agent=1&text=… はチャットの入力欄から送ったのと同じ（作業中・予約の途中なら予約に足す）。
            // to=2・pass=1|0 を付けると送り先・前の結果を渡すかを決めて予約に足す。
            // do=pause|resume|skip|clear|stop、do=edit&index=0&text=…（行の文を書き換える）、do=move&index=1&by=-1
            if let c = agent {
                let id = c.record.id
                let items = manager.queues.items(id)
                // index=last で最後の行（デモの録画で、前の行が送られたあとでも同じ行を指せるように）
                let row = param("index") == "last" ? items.last
                    : param("index").flatMap(Int.init).flatMap { $0 >= 0 && $0 < items.count ? items[$0] : nil }
                switch param("do") ?? "" {
                case "pause": manager.queues.pause(owner: id)
                case "resume": manager.queues.resume(owner: id)
                case "skip": manager.queues.skipCurrent(owner: id)
                case "clear": manager.queues.clear(owner: id)
                case "stop": manager.runtime(for: c)?.cancel()
                case "edit":
                    if let row, let t = param("text") {
                        manager.queues.update(owner: id, item: row.id, text: t)
                        if param("hold") != "1" { manager.queues.endEditing(owner: id, item: row.id) }
                    }
                case "target":
                    if let row, let to = param("to").flatMap(Int.init).flatMap({ manager.controller(number: $0) }) {
                        manager.queues.update(owner: id, item: row.id, target: .some(to.record.id))
                    }
                case "move":
                    if let row { manager.queues.move(owner: id, item: row.id, by: param("by").flatMap(Int.init) ?? 0) }
                case "remove":
                    if let row { manager.queues.remove(owner: id, item: row.id) }
                default:
                    guard let text = param("text") else { break }
                    let to = param("to").flatMap(Int.init).flatMap { manager.controller(number: $0) }?.record.id
                    if to != nil || param("pass") != nil {
                        manager.queues.enqueue(owner: id, text: text, target: to, passResult: param("pass").map { $0 == "1" })
                    } else {
                        manager.submitFromChat(c, text: text)
                    }
                }
            }
        case "chatshot":
            // テスト用：チャットの窓の中身を、データフォルダの shots/<name>.png に描く（画面には出さない）
            if let c = agent, let name = param("name"), name.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil {
                let dir = AppPaths.dataDir.appendingPathComponent("shots", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                AppLog.write("chatshot \(name) ok=\(manager.snapshotChat(c, to: dir.appendingPathComponent(name + ".png")))")
            }
        case "open":
            if let c = agent { manager.openChat(for: c, activate: automation) }
        case "permissions":
            // 「🔐 権限」の画面を出す（表示だけ。許可を求めるのは、本人がその画面で「まとめて許可する」を押したあとの続きだけ）
            manager.showPermissions(done: param("done"))
        case "watchtest":
            // テスト用（合言葉つきの自動化のときだけ）：見守りの吹き出しを見本の画像で出す
            manager.debugWatchFinding()
        case "connectors":
            // デモの録画用（合言葉つきの自動化のときだけ）：コネクタの画面を前面化せずに出し、x・y（左上）に置き、press のボタンを押す
            let p = param("x").flatMap(Double.init).flatMap { x in param("y").flatMap(Double.init).map { NSPoint(x: x, y: $0) } }
            manager.debugConnectors(topLeft: p, press: param("press"), close: param("close") == "1")
        case "connectortest":
            // デモの録画用：書き込みの確認の吹き出しを見本で出す（answer=yes|no で押す。何も書き込まない）
            manager.debugConnectorConfirm(agent, answer: param("answer"))
        case "accounts":
            // 自動化（合言葉つき）のときだけ：アカウントと AI の画面
            manager.showAccounts()
        case "window":
            // テスト用（合言葉つきの自動化のときだけ）：チャットの窓を操作する（minimize / fullscreen / esc / close）
            if let c = agent { manager.debugChatWindow(c, param("do") ?? "") }
        case "debug":
            for c in manager.controllers {
                let r = c.record
                AppLog.write("agent \(r.number) \(r.color.key) state=\(r.state.rawValue) visible=\(c.isVisible) animating=\(c.isAnimating) frame=\(NSStringFromRect(c.panel.frame))")
            }
            // アプリの状態とメニュー（Dock に出ているか・メニューバーの中身）、チャットの窓の状態
            let policy: String
            switch NSApp.activationPolicy() {
            case .regular: policy = "regular"
            case .accessory: policy = "accessory"
            default: policy = "prohibited"
            }
            let menus = (NSApp.mainMenu?.items ?? []).map { m in
                m.title + ": " + (m.submenu?.items.map { i in
                    i.isSeparatorItem ? "-" : i.title + (i.isHidden ? "(hidden)" : "") + (i.isAlternate ? "(alt)" : "")
                        + (i.action.map { "<\(NSStringFromSelector($0))>" } ?? "")
                }.joined(separator: ", ") ?? "")
            }
            AppLog.write("app policy=\(policy) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) menus=[\(menus.joined(separator: " | "))]")
            for line in manager.debugChatLines() { AppLog.write(line) }
            for line in manager.debugQueueLines() { AppLog.write(line) }
        case "style":
            if let st = param("v").flatMap(AvatarStyle.init(rawValue:)) { manager.setStyle(st) }
        case "login":
            let want = param("on") == "1"
            let err = LoginItem.set(want)
            AppLog.write("login item set(\(want)) -> \(err ?? "ok"), status=\(LoginItem.statusText)")
            manager.updateSettings { $0.launchAtLogin = LoginItem.isEnabled }
        case "scale":
            if let v = param("v").flatMap(Double.init) { manager.setScale(min(max(v, 0.5), 2.0)) }
        default: break
        }
    }
}

/// jellyfish:// のどの操作を受け付けるか
enum URLRoutes {
    /// 外から呼ばれても困らない操作（表示の切り替え・新しいクラゲ・チャットを開く・見た目）
    static let publicRoutes: Set<String> = ["new", "toggle", "show", "hide", "arrange", "open", "style", "scale", "permissions"]

    static var automationEnabled: Bool { ProcessInfo.processInfo.environment["JELLYFISH_AUTOMATION"] == "1" }

    /// 自動化（JELLYFISH_AUTOMATION=1）で起動したときだけ作る合言葉。データフォルダの automation.token（本人だけが読める）に書き、
    /// URL に token=… が付いているときだけ公開以外の操作を受け付ける。環境変数が何かの拍子に付いたままになっても、
    /// 合言葉を読めない Web ページからは公開の操作しかできない
    static let automationToken: String? = {
        let url = AppPaths.dataDir.appendingPathComponent("automation.token")
        guard automationEnabled else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // SystemRandomNumberGenerator は macOS では暗号用の乱数（arc4random_buf）
        var rng = SystemRandomNumberGenerator()
        let token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return token
    }()

    static func allowed(_ url: URL, automationToken: String?) -> Bool {
        guard url.scheme?.lowercased() == "jellyfish" else { return false }
        if isAutomation(url, token: automationToken) { return true }
        let host = (url.host ?? "").lowercased()
        guard publicRoutes.contains(host) else { return false }
        // 作業フォルダの指定は自動化のときだけ
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host == "new", q.contains(where: { $0.name == "cwd" }) { return false }
        return true
    }

    /// 合言葉つきの（scripts/demo の録画からの）呼び出しか
    static func isAutomation(_ url: URL, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let given = q.first(where: { $0.name == "token" })?.value else { return false }
        // 長さと中身を、途中で抜けずに比べる
        let a = Array(given.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// 外から続けざまに呼ばれても困らないように（Web ページが jellyfish://new を繰り返し開くなど）。
    /// 新しいクラゲは 3 秒に 1 回、それ以外の操作は 0.3 秒に 1 回まで
    struct Throttle {
        private var last: [String: Date] = [:]
        mutating func allow(_ host: String, now: Date = Date()) -> Bool {
            let gap: TimeInterval = host == "new" ? 3 : 0.3
            if let t = last[host], now.timeIntervalSince(t) < gap { return false }
            last[host] = now
            return true
        }
    }
}
