import Foundation

/// 1 回の指示とその結果
struct AgentTurn: Codable {
    var prompt: String
    var startedAt: Date
    var endedAt: Date?
    var state: AgentState
    var result: String?
    var error: String?
    var costUSD: Double?
    var tools: [String] = []
    /// このターンを動かした AI（チャットの見出しに使う。古い記録では無い）
    var engine: String?
}

/// おもち1体ぶんのエージェント。セッション・プロセス・履歴・ログ・作業フォルダを他と共有しない。
/// 各ターンは独立した OS プロセスなので、1体が落ちても他のおもちには影響しない。
final class AgentRuntime {
    let agentID: UUID
    let dir: URL
    private(set) var turns: [AgentTurn] = []
    private(set) var sessionID: String
    private(set) var sessionStarted: Bool
    /// いまの会話（sessionID）を作った AI。既定の AI が変わったら、続きにせず新しい会話にする
    private(set) var sessionEngine: AgentEngine?
    private(set) var cwd: URL
    /// おもちごとのモデル・強さ（nil = 既定）
    var model: String? { didSet { saveMeta() } }
    var effort: String? { didSet { saveMeta() } }
    /// このエージェントに PC 操作（画面・マウス・キー）を許すか。既定はオフ
    var pcControl: Bool = false { didSet { saveMeta() } }
    /// 見守り（画面のエラーっぽい表示に気づいたら聞く）。既定はオフ
    var watchScreen: Bool = false { didSet { saveMeta() } }
    /// 大福の「あんこ」：このおもちがいつも参照するファイル・フォルダ（落としたもの。専門分野として毎回の案内に入る）
    var anko: [String] = [] { didSet { if anko != oldValue { saveMeta(); onLook?() } } }
    /// ちぎった（分岐した）元の会話。最初の指示で、その会話を写した新しい会話として始める
    struct ForkSource: Codable, Equatable {
        /// 元の会話の ID（AI の CLI の会話）
        var session: String
        /// 元の会話を作った AI
        var engine: String
        /// 元のおもちの名前（チャットの表示用）
        var name: String
        /// 元の会話の作業フォルダ（Claude Code の会話はフォルダごとに保存されるので、違うフォルダでは写せない）
        var cwd: String? = nil
    }
    private(set) var forkSource: ForkSource?
    /// いまの会話の大きさ（トークン）と、モデルの文脈の上限（分かったものだけ）
    private(set) var contextTokens: Int?
    private(set) var contextWindow: Int?
    /// 見た目（ふくらみ・焦げ目・あんこ）にかかわる値が変わった
    var onLook: (() -> Void)?

    /// 現在の動作の 1 行説明（「Bash: npm test」など）
    private(set) var activity: String?
    /// 実際に使われたモデル（Claude Code の init イベントから）
    private(set) var activeModel: String?
    /// このターンで CLI に渡したモデル（nil = CLI の既定）と、このターンで CLI がモデルを知らせたか
    private(set) var plannedModel: String?
    private var modelReportedThisTurn = false
    /// コネクタの「使ってよいモデル」の判定に使うモデル：このターンで CLI が知らせたもの → 渡したもの → 前のターンのもの（推測）
    var connectorModel: String? { (modelReportedThisTurn ? activeModel : nil) ?? plannedModel ?? activeModel }
    /// モデルが「自動」のときに、このターンで選んだモデルと理由
    private(set) var autoChoice: ModelRouter.Choice?
    private(set) var permissionMode: String?
    private var cachedSessionFile: URL?
    private var cachedTitle: (date: Date, title: String)?
    private(set) var lastError: String?

    var onState: ((AgentState) -> Void)?
    var onUpdate: (() -> Void)?
    /// ターンが終わったとき（チームの依頼の結果を返すのに使う）
    var onTurnEnded: ((AgentTurn) -> Void)?
    /// 実行ごとのチーム設定（MCP・system prompt）。nil を返せばチーム機能なしで動く
    var teamConfig: (() -> TeamCoordinator.RunConfig?)?
    /// 外部の MCP サーバーをこのターンで読み込むか（指示文・作業フォルダ・この会話ですでに読み込んだか）
    var mcpPolicy: ((String, URL, Bool) -> MCPDecision)?
    struct MCPDecision {
        let load: Bool
        /// 設定されている外部サーバー（読み込まないときにエージェントへ伝える）
        let servers: [String]
        let note: String?
    }
    /// このターンで読み込んだ外部 MCP サーバー（空 = 読み込んでいない）
    private(set) var externalLoaded: [String] = []
    /// 外部 MCP を読み込んだ会話（同じ会話の続きでは読み込んだままにする）
    private var externalMCPSession: String?

    private var handle: AgentHandle?
    private var pendingTools = 0
    private var cancelRequested = false
    private var gotResult = false
    /// おもちごとのエンジン（nil = メニューバーの「使う AI」の既定）を受けて、そのバックエンドを返す
    private let backendProvider: (AgentEngine?) -> AgentBackend?
    /// このおもちが使う AI（nil = 既定）。変えると新しい会話になる
    private(set) var engine: AgentEngine?
    /// 実行の前の確認（ログインしていない・API キーの従量課金など、使わない理由があれば返す）
    var preflight: ((AgentBackend) -> String?)?
    /// このターンで作業フォルダのほかに使ってよいフォルダ（チームの受け渡し用のフォルダ）
    var extraDirs: (() -> [URL])?
    /// 使ったトークン（エンジン・モデルごと。使用量の表示用）
    var onUsage: ((AgentEngine, String?, Int, Int, Int) -> Void)?
    /// いまのターンの CLI が会話の ID を自分で決めるか（Codex）
    private var adoptSession = false
    /// いまのターンは、ちぎった元の会話を写して始めている
    private var runningForked = false
    /// AI が違う分身に渡す、元のおもちの会話（ちぎったときに書いておく）
    var forkContextFile: URL { dir.appendingPathComponent("fork-context.md") }
    /// いまのターンのエンジン
    private(set) var runningEngine: AgentEngine?

    var isRunning: Bool { handle != nil }
    var processID: Int32? { handle?.processID }

    /// 「デスクトップの〇〇を開いて」で、中身をチャットに書き写すのではなく Mac のアプリで開くように
    /// （claude -p はターミナル向けなので、何も言わないと cat で中身を表示して終わることがある）
    static var desktopNote: String { L("# OMOCHI AI（Mac のデスクトップアプリ）から\nあなたは Mac のデスクトップに常駐するアプリ OMOCHI AI から呼ばれています。ユーザーがファイル・フォルダ・URL を「開いて」「表示して」「見せて」と頼んだときは、中身をチャットに書き写すのではなく、`open` コマンドで Mac の既定のアプリ（プレビュー・テキストエディット・Finder・ブラウザなど）で開いてください。開いたら「〇〇を〇〇で開きました」と短く伝えれば十分です（中身の説明や要約は頼まれたときだけ）。開くのはユーザーが頼んだものだけにしてください。") }

    /// チャットに出せる書き方（どの AI にも同じ文を渡す。毎回同じなのでプロンプトキャッシュは崩れない）
    static var chatFormatNote: String { L("# チャットの表示\nあなたの返答は OMOCHI AI のチャットで Markdown として表示されます。表（| 列 | 列 |）、数式（文中は $…$、別の行は $$…$$。KaTeX）、図・グラフ（```mermaid のコードブロック：flowchart・sequenceDiagram・pie・xychart-beta など。xychart の日本語のラベルは \"\" で囲む）、言語名つきのコードブロックが、そのまま表・数式・図として見えます。表やグラフにすると分かりやすいときは使ってください。画像のファイルを作ったときは、その絶対パスを書くとサムネイルが出ます。") }

    init(agentID: UUID, baseDir: URL, backendProvider: @escaping (AgentEngine?) -> AgentBackend?) {
        self.agentID = agentID
        self.backendProvider = backendProvider
        dir = baseDir.appendingPathComponent("agents/\(agentID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let meta = AgentRuntime.loadMeta(dir)
        // meta.json の ID が UUID でなければ（書き換えられたなど）新しいセッションにする（--resume に渡すため）
        let validMeta = meta.map { UUID(uuidString: $0.sessionID) != nil } ?? false
        sessionID = validMeta ? meta!.sessionID : UUID().uuidString.lowercased()
        sessionStarted = validMeta ? (meta?.sessionStarted ?? false) : false
        sessionEngine = validMeta ? meta?.sessionEngine.flatMap(AgentEngine.init(rawValue:)) : nil
        cwd = URL(fileURLWithPath: meta?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
        model = meta?.model
        effort = meta?.effort
        pcControl = meta?.pcControl ?? false
        watchScreen = meta?.watchScreen ?? false
        engine = meta?.engine.flatMap(AgentEngine.init(rawValue:))
        externalMCPSession = meta?.externalMCPSession
        anko = meta?.anko ?? []
        forkSource = meta?.fork
        contextTokens = meta?.contextTokens
        contextWindow = meta?.contextWindow
        turns = AgentRuntime.loadTurns(dir)
        // 前回アプリ終了時に実行中だったターンは中断扱い
        if let last = turns.last, !last.state.isTerminal && last.state != .error {
            turns[turns.count - 1].state = .error
            turns[turns.count - 1].error = L("アプリの終了により中断されました")
            turns[turns.count - 1].endedAt = Date()
            saveTurns()
        }
        saveMeta()
    }

    var lastTurn: AgentTurn? { turns.last }

    /// 最後に作業した時刻（硬さの目安）。履歴が無い（過去のセッションを呼び出した）ときは会話の記録の更新時刻
    var lastActiveAt: Date? {
        if let t = turns.last { return t.endedAt ?? t.startedAt }
        guard let f = sessionFile else { return nil }
        return (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 指示の添付の欄（添付ファイル・画面の画像）にある、実在するファイル
    static func attachedFiles(in text: String) -> [URL] {
        let markers = [AgentChatController.attachMarker, ScreenContext.marker]
        guard let start = markers.compactMap({ text.range(of: $0)?.lowerBound }).min() else { return [] }
        var out: [URL] = []
        for line in text[start...].split(separator: "\n") where line.hasPrefix("- /") {
            let p = String(line.dropFirst(2))
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue {
                let u = URL(fileURLWithPath: p)
                if !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    /// 指示を送る（実行中なら何もしない）
    @discardableResult
    func submit(_ prompt: String) -> Bool {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return false }
        guard let backend = backendProvider(engine) else {
            refuse(text, L("%@ が見つかりません。メニューバーのおもち › 🔑 アカウントと AI で、入っているか・ログインしているかを確かめてください", (engine ?? defaultEngine?() ?? .claude).cliTitle))
            return false
        }
        // ログインしていない・API キー（従量課金）でログインしている、などのときは動かさない（勝手に課金しない）
        if let why = preflight?(backend) {
            refuse(text, why)
            return false
        }
        // 会話は AI ごとに別。既定の AI が変わってこのおもちの AI が変わったときは、前の AI の会話を続けようとせず新しい会話にする
        // （モデル・強さの指定も前の AI のものなので外す。PC 操作は Claude だけ）
        if let se = sessionEngine, se != backend.engine {
            sessionID = UUID().uuidString.lowercased()
            sessionStarted = false
            cachedSessionFile = nil
            cachedTitle = nil
            model = nil
            effort = nil
            contextTokens = nil
            contextWindow = nil
            if !backend.engine.supportsOmochiTools { pcControl = false }
            AppLog.write("agent \(agentID.uuidString.prefix(8)) engine \(se.rawValue) -> \(backend.engine.rawValue): new session")
        }
        // ちぎった分身の最初の指示：同じ AI なら元の会話を写して続ける（Claude --fork-session・Codex exec fork）。
        // AI が違う・その CLI で写せないときは、元の会話を指示に添えて渡す
        var forkFrom: String?
        if let f = forkSource, !sessionStarted {
            if f.engine == backend.engine.rawValue, backend.canFork,
               f.cwd.map({ URL(fileURLWithPath: $0).standardizedFileURL == cwd.standardizedFileURL }) ?? true {
                forkFrom = f.session
            } else {
                text += MochiPlay.forkContextBlock(name: f.name, transcript: (try? String(contentsOf: forkContextFile, encoding: .utf8)) ?? "")
                forkSource = nil
                try? FileManager.default.removeItem(at: forkContextFile)
            }
        }
        // 大福のあんこ（Gemini には system prompt を足すオプションが無いので指示に添える）
        let ankoNote = MochiPlay.ankoNote(anko)
        if backend.engine == .gemini, let n = ankoNote { text += MochiPlay.ankoMarker + "\n" + n }
        sessionEngine = backend.engine
        saveMeta()
        var turn = AgentTurn(prompt: text, startedAt: Date(), state: .thinking)
        turn.engine = backend.engine.rawValue
        turns.append(turn)
        saveTurns()
        pendingTools = 0
        cancelRequested = false
        gotResult = false
        activity = L("考えています…")
        lastError = nil
        onState?(.thinking)
        onUpdate?()

        // 前のターンが始まりの知らせ（init）を受け取る前に止まっていても、Claude Code がこの ID の記録を作っていれば続きとして開く
        // （作り直そうとすると「Session ID … is already in use」で失敗する）
        if !sessionStarted, backend.engine == .claude, ClaudeSessions.file(for: sessionID) != nil {
            sessionStarted = true
            saveMeta()
        }
        let resume = sessionStarted
        adoptSession = backend.assignsSessionID
        runningEngine = backend.engine
        var opts = AgentRunOptions(model: model, effort: effort)
        opts.forkFrom = forkFrom
        let claude = backend.engine == .claude
        if !claude {
            // Codex・Gemini：おもちで選んだモデル（無ければ設定の既定、それも無ければ CLI の既定）。強さは Codex だけ。
            // モデルの「自動」（Claude の振り分け）・チーム・PC 操作・外部 MCP・追加の案内は渡さない
            opts.model = model
            opts.effort = backend.engine == .codex ? effort : nil
            autoChoice = nil
        } else if (model ?? backend.defaultModel) == ModelRouter.auto {
            // 「自動」：依頼ごとに合うモデルを選ぶ（おもちの指定が無ければ設定の既定に従う）
            let attached = text.contains(AgentChatController.attachMarker) || text.contains(ScreenContext.marker)
            let typed = AgentChatController.typedPrompts([text]).first ?? text
            let c = ModelRouter.choose(typed, attachments: attached, fableUsedPercent: ClaudeAccount.shared.fableUsedPercent)
            opts.model = c.model
            autoChoice = c
        } else {
            autoChoice = nil
        }
        // コネクタの判定に使うモデル（「自動」は選んだモデル、指定が無ければ設定の既定。どちらも無ければ CLI の既定 = 分からない）
        plannedModel = (opts.model ?? backend.defaultModel).flatMap { $0.isEmpty || $0 == ModelRouter.auto ? nil : $0 }
        modelReportedThisTurn = false
        // チームのツール（OMOCHI AI の MCP）：Claude は --mcp-config、Codex・Gemini はそれぞれの CLI の設定の形で渡す
        if let t = teamConfig?() {
            if claude {
                opts.mcpConfig = t.mcpConfig
                opts.appendSystemPrompt = t.systemPrompt
                opts.allowedTools = t.allowedTools
                opts.env = t.env
            } else {
                opts.mcpBridge = t.bridge
                opts.mcpTools = t.toolNames
                opts.instructions = t.systemPrompt
            }
        }
        if claude, let d = mcpPolicy?(text, cwd, externalMCPSession == sessionID) {
            if d.load {
                externalLoaded = d.servers.isEmpty ? ["claude.ai"] : d.servers
                if externalMCPSession != sessionID { externalMCPSession = sessionID; saveMeta() }
            } else {
                externalLoaded = []
                opts.strictMCPConfig = true
                if let n = d.note { opts.appendSystemPrompt = [opts.appendSystemPrompt, n].compactMap { $0 }.joined(separator: "\n\n") }
            }
        }
        // デスクトップのアプリとしての振る舞い（毎回同じ文なのでプロンプトキャッシュは崩れない）
        if claude { opts.appendSystemPrompt = [AgentRuntime.desktopNote, AgentRuntime.chatFormatNote, opts.appendSystemPrompt].compactMap { $0 }.joined(separator: "\n\n") }
        // Codex は developer_instructions に（Gemini はチームのツールの説明で渡す）
        if backend.engine == .codex { opts.instructions = [AgentRuntime.chatFormatNote, opts.instructions, ankoNote].compactMap { $0 }.joined(separator: "\n\n") }
        if claude, let n = ankoNote { opts.appendSystemPrompt = [opts.appendSystemPrompt, n].compactMap { $0 }.joined(separator: "\n\n") }
        // チームの受け渡し用のフォルダ（どの AI でも読み書きできるように渡す）
        opts.addDirs = extraDirs?() ?? []
        // あんこの置き場所を読めるように（Claude --add-dir・Gemini --include-directories。Codex は書き込める場所を広げないので渡さない）
        if backend.engine != .codex {
            for d in MochiPlay.ankoDirs(anko) where !opts.addDirs.contains(d) && d.standardizedFileURL != cwd.standardizedFileURL { opts.addDirs.append(d) }
        }
        // 添付（画面の画像・落としたファイル・システムの音の文字起こし）を、どの AI でも読めるように
        // 仲間からの依頼の文（エージェントが書いたもの）にある「- /パス」は添付として扱わない
        let files = text.hasPrefix(TeamCoordinator.requestMarker) ? [] : AgentRuntime.attachedFiles(in: text)
        switch backend.engine {
        case .codex:
            // Codex はファイルを読めても画像は見られないので、画像は --image で添える
            // --image はカンマで区切って読まれることがあるので、カンマの入った場所は渡さない
            opts.images = Array(files.filter { ChatMedia.imageExts.contains($0.pathExtension.lowercased()) && !$0.path.contains(",") }.prefix(8))
        case .gemini:
            // Gemini はワークスペースの外のファイルを読めないので、このおもちのデータフォルダの中の添付（画面の画像・文字起こし）の置き場所だけ足す
            let own = dir.standardizedFileURL.path + "/"
            for d in Set(files.map { $0.deletingLastPathComponent().standardizedFileURL }) where d.path.hasPrefix(own) && !opts.addDirs.contains(d) {
                opts.addDirs.append(d)
            }
        case .claude: break
        }
        runningForked = forkFrom != nil
        do {
            handle = try backend.run(prompt: text, sessionID: sessionID, resume: resume, cwd: cwd, logDir: dir,
                                     options: opts,
                                     onEvent: { [weak self] e in self?.handle(e) },
                                     onExit: { [weak self] status, err in self?.exited(status: status, stderr: err) })
            AppLog.write("agent \(agentID.uuidString.prefix(8)) run engine=\(backend.engine.rawValue) resume=\(resume) model=\(model ?? "-")\(autoChoice.map { "→\($0.model)" } ?? "") effort=\(effort ?? "-") external=\(opts.strictMCPConfig ? "off" : externalLoaded.joined(separator: ",")) cwd=\(cwd.path)")
        } catch {
            finish(.error, error: L("起動に失敗しました: %@", error.localizedDescription))
        }
        return true
    }

    func cancel() {
        guard let h = handle else { return }
        cancelRequested = true
        activity = L("キャンセルしています…")
        onUpdate?()
        h.cancel()
    }

    /// 直前の指示をもう一度
    func retry() {
        guard !isRunning, let last = turns.last else { return }
        submit(last.prompt)
    }

    // MARK: - イベント → 状態（実イベントだけで判定）

    private func handle(_ e: AgentEvent) {
        guard !turns.isEmpty else { return }
        let i = turns.count - 1
        switch e {
        case .started(let session, let model, let mode):
            // ちぎった会話が新しい会話として始まったら、元の会話の写しはもう要らない
            if forkSource != nil, runningForked, session != nil {
                forkSource = nil
                try? FileManager.default.removeItem(at: forkContextFile)
                saveMeta()
            }
            if let s = session, s == sessionID { sessionStarted = true; saveMeta() }
            // Codex は会話の ID を自分で決めるので、受け取った ID（UUID の形のときだけ）を次の続きに使う
            else if adoptSession, let s = session, UUID(uuidString: s) != nil {
                sessionID = s
                sessionStarted = true
                cachedSessionFile = nil
                saveMeta()
            }
            self.activeModel = model
            if model?.isEmpty == false { modelReportedThisTurn = true }
            self.permissionMode = mode
        case .thinking:
            if pendingTools == 0 { setTurnState(.thinking); activity = L("考えています…") }
        case .text(let t):
            if pendingTools == 0 { setTurnState(.thinking) }
            activity = String(t.replacingOccurrences(of: "\n", with: " ").prefix(90))
        case .toolStarted(let name, let summary):
            pendingTools += 1
            turns[i].tools.append(name)
            activity = summary
            setTurnState(.working)
        case .toolFinished:
            pendingTools = max(0, pendingTools - 1)
            if pendingTools == 0 { setTurnState(.thinking) }
        case .usage(let m, let input, let output, let cached):
            onUsage?(runningEngine ?? effectiveEngine, m ?? activeModel ?? model, input, output, cached)
            return
        case .context(let tokens, let window):
            if let t = tokens { contextTokens = t }
            if let w = window { contextWindow = w }
            onLook?()
            return
        case .finished(let success, let result, let cost, _):
            gotResult = true
            turns[i].result = result
            turns[i].costUSD = cost
            if cancelRequested {
                turns[i].state = .cancelled
            } else {
                turns[i].state = success ? .completed : .error
                if !success { turns[i].error = result }
            }
        }
        onUpdate?()
    }

    private func setTurnState(_ s: AgentState) {
        guard let last = turns.last, last.state != s else { return }
        turns[turns.count - 1].state = s
        onState?(s)
    }

    private func exited(status: Int32, stderr: String) {
        handle = nil
        guard let last = turns.last else { return }
        if cancelRequested {
            finish(.cancelled, error: nil)
        } else if gotResult {
            finish(last.state == .completed ? .completed : .error, error: last.error)
        } else {
            let msg = stderr.isEmpty ? L("プロセスが終了しました（コード %ld）", Int(status)) : stderr
            finish(.error, error: msg)
        }
    }

    private func finish(_ s: AgentState, error rawError: String?) {
        let error = rawError.map { AgentRuntime.friendlyError($0, engine: runningEngine) }
        handle = nil
        if !turns.isEmpty {
            let i = turns.count - 1
            turns[i].state = s
            turns[i].endedAt = Date()
            if let error { turns[i].error = error }
        }
        activity = nil
        lastError = error
        saveTurns()
        onState?(s)
        onUpdate?()
        if let t = turns.last { onTurnEnded?(t) }
    }

    /// CLI のエラーを、どうすればよいか分かる文にする
    static func friendlyError(_ e: String, engine: AgentEngine?) -> String {
        if engine == .gemini, e.contains("trusted directory") {
            return L("Gemini がこのフォルダを信頼していないので動けません。チャットの「Gemini をこのフォルダで開く」から Gemini を開き、信頼してよいフォルダのときだけ信頼してください。")
        }
        return e
    }

    // MARK: - Claude Code のセッション記録

    /// このおもちの会話が残っている Claude Code のセッションファイル
    var sessionFile: URL? {
        guard sessionStarted else { return nil }
        if let f = cachedSessionFile, FileManager.default.fileExists(atPath: f.path) { return f }
        cachedSessionFile = ClaudeSessions.file(for: sessionID)
        return cachedSessionFile
    }

    /// Claude Code が付けたセッションのタイトル（更新時刻で キャッシュ）
    var sessionTitle: String? {
        guard let f = sessionFile else { return nil }
        let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let c = cachedTitle, c.date == m { return c.title }
        guard let info = ClaudeSessions.info(file: f, modified: m), info.title != "（無題のセッション）", info.title != L("（無題のセッション）") else { return nil }
        cachedTitle = (m, info.title)
        return info.title
    }

    /// 既定の AI（エンジン）。メニューバーの「使う AI」
    var defaultEngine: (() -> AgentEngine)?

    /// 実際に使う AI
    var effectiveEngine: AgentEngine { engine ?? defaultEngine?() ?? .claude }

    /// AI を変える（nil = 既定に従う）。会話は AI ごとに別なので、新しい会話になる。モデルの指定も外す
    func changeEngine(_ e: AgentEngine?) {
        guard !isRunning, e != engine else { return }
        let before = effectiveEngine
        engine = e
        // PC 操作は Claude だけ
        if !effectiveEngine.supportsOmochiTools { pcControl = false }
        if effectiveEngine != before {
            sessionID = UUID().uuidString.lowercased()
            sessionStarted = false
            sessionEngine = nil
            cachedSessionFile = nil
            cachedTitle = nil
            model = nil
            effort = nil
            contextTokens = nil
            contextWindow = nil
        }
        saveMeta()
        onUpdate?()
        onLook?()
    }

    /// 動かさない理由をターンとして残す
    private func refuse(_ text: String, _ why: String) {
        lastError = why
        turns.append(AgentTurn(prompt: text, startedAt: Date(), endedAt: Date(), state: .error, error: why))
        saveTurns()
        onState?(.error)
        onUpdate?()
    }

    /// ちぎった分身にする：最初の指示で元の会話を写して始める。AI が違うときに渡す会話の写しも書いておく
    func setForkSource(_ f: ForkSource?, transcript: String?) {
        forkSource = f
        if let t = transcript, !t.isEmpty {
            try? t.write(to: forkContextFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: forkContextFile)
        }
        saveMeta()
        onUpdate?()
    }

    /// 会話の大きさを写す（分身は元と同じ大きさから始まる）・忘れる（新しい会話）
    func setContext(tokens: Int?, window: Int?) {
        contextTokens = tokens
        contextWindow = window
        saveMeta()
        onLook?()
    }

    /// 作業フォルダを変える。Claude Code のセッションはフォルダ（プロジェクト）ごとに保存されるので新しいセッションになる
    func changeFolder(_ url: URL) {
        guard !isRunning, url.standardizedFileURL != cwd.standardizedFileURL else { return }
        cwd = url
        sessionID = UUID().uuidString.lowercased()
        sessionStarted = false
        sessionEngine = nil
        cachedSessionFile = nil
        cachedTitle = nil
        if forkSource == nil { contextTokens = nil; contextWindow = nil }
        saveMeta()
        onUpdate?()
        onLook?()
    }

    /// 既存の Claude Code セッション（過去のプロジェクト）をこのおもちで続ける
    func bind(to info: ClaudeSessionInfo) {
        guard !isRunning, UUID(uuidString: info.id) != nil else { return }
        sessionID = info.id
        sessionStarted = true
        // Claude Code のセッションなので、このおもちは Claude で続ける
        if effectiveEngine != .claude { engine = .claude }
        sessionEngine = .claude
        cachedSessionFile = info.file
        cachedTitle = nil
        if let c = info.cwd { cwd = URL(fileURLWithPath: c, isDirectory: true) }
        saveMeta()
        onUpdate?()
    }

    // MARK: - 永続化

    private struct Meta: Codable {
        var sessionID: String; var sessionStarted: Bool; var cwd: String
        var model: String?; var effort: String?
        var pcControl: Bool?
        var watchScreen: Bool?
        var externalMCPSession: String?
        var engine: String?
        var sessionEngine: String?
        var anko: [String]?
        var fork: ForkSource?
        var contextTokens: Int?
        var contextWindow: Int?
    }

    private static func loadMeta(_ dir: URL) -> Meta? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: d)
    }

    private func saveMeta() {
        let m = Meta(sessionID: sessionID, sessionStarted: sessionStarted, cwd: cwd.path, model: model, effort: effort,
                     pcControl: pcControl, watchScreen: watchScreen, externalMCPSession: externalMCPSession, engine: engine?.rawValue,
                     sessionEngine: sessionEngine?.rawValue, anko: anko.isEmpty ? nil : anko, fork: forkSource,
                     contextTokens: contextTokens, contextWindow: contextWindow)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: dir.appendingPathComponent("meta.json"), options: .atomic) }
    }

    private static func loadTurns(_ dir: URL) -> [AgentTurn] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("history.json")) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([AgentTurn].self, from: d)) ?? []
    }

    private func saveTurns() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(turns) { try? d.write(to: dir.appendingPathComponent("history.json"), options: .atomic) }
    }

    /// おもちを消したときに、ツールの結果を含む生イベントと画面の画像を消す。
    /// 会話は Claude Code のセッションに残り（「過去のセッションを開く」で戻せる）、文字起こしはユーザーの資料なので残す
    func deleteScratchFiles() {
        let fm = FileManager.default
        for name in AgentRuntime.scratchNames { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }

    /// おもちを消したときに消すもの（生イベント・画面の画像・ターミナルで開く用のスクリプト）
    static let scratchNames = ["events.jsonl", "events.1.jsonl", "attachments", "screens", "open-in-claude.command"]
}
