import AppKit

/// お餅の性質を使った操作（ちぎる・くっつく・鏡餅・串だんご・大福・ふくらむ／硬くなる・温め直す）
extension JellyManager {
    /// ちぎれるまでの距離（体の幅の倍数）
    static let tearDistance: CGFloat = 1.3

    // MARK: - 見た目（会話の大きさ・硬さ・あんこ・鏡餅・温め直し）

    func refreshLook(_ c: JellyController) {
        guard let rt = runtimes[c.record.id] else { return }
        let ratio = MochiPlay.contextRatio(tokens: rt.contextTokens, window: rt.contextWindow)
        var l = MochiLook()
        l.fullness = MochiPlay.fullness(ratio)
        l.char = MochiPlay.charLevel(ratio)
        l.hard = rt.isRunning || !rt.sessionStarted ? 0 : MochiPlay.hardness(lastActive: rt.lastActiveAt)
        l.anko = !rt.anko.isEmpty
        l.crown = controllers.contains { $0.record.leaderID == c.record.id }
        l.warming = rt.isRunning && (rt.lastTurn?.prompt.hasPrefix(MochiPlay.warmPrefix) ?? false)
        c.avatar.setLook(l)
    }

    func refreshAllLooks() { controllers.forEach { refreshLook($0) } }

    /// 硬さは時間で変わるので、1 分ごとに見直す（見た目が変わるときだけ描き直す）
    func startLookTimer() {
        refreshAllLooks()
        lookTimer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshAllLooks()
            for (_, chat) in self.chats where chat.isVisible { chat.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        lookTimer = t
    }

    /// おもちが消えるとき：串・鏡餅・ちぎっている途中から外す
    func mochiRemoved(_ id: UUID) {
        if tearState?.clone == id || tearState?.origin == id { tearState = nil }
        var changed = false
        for c in controllers where c.record.leaderID == id { c.update { $0.leaderID = nil }; changed = true }
        let before = skewers
        skewers = skewers.compactMap { s in
            var s = s
            if let i = s.members.firstIndex(of: id) {
                s.members.remove(at: i)
                if i < s.steps.count { s.steps.remove(at: i) }
            }
            return s.members.count >= (s.org ? 1 : 2) ? s : nil
        }
        if skewers != before { saveSkewers(); changed = true }
        if changed { DispatchQueue.main.async { [weak self] in self?.refreshAllLooks(); self?.team?.refresh() } }
    }

    // MARK: - ちぎる（分岐）

    /// 分身を作る（まだ画面には出さない）。同じ作業フォルダ・モデル・あんこ・会話の大きさを受け継ぎ、
    /// 最初の指示で元の会話を写した新しい会話として始める（AI が違えば、元の会話を指示に添えて渡す）
    func makeClone(of c: JellyController, engine: AgentEngine? = nil, at origin: NSPoint) -> JellyController? {
        guard controllers.count < TeamCoordinator.maxAgents, let ort = runtimes[c.record.id] else { return nil }
        var r = makeRecord()
        r.name = uniqueName(MochiPlay.cloneName(c.record.title))
        r.forkOf = c.record.id
        r.origin = origin
        let n = addController(r)
        guard let rt = runtimes[n.record.id] else { return n }
        let e = engine ?? ort.effectiveEngine
        rt.changeEngine(e == settings.engine && ort.engine == nil ? nil : e)
        rt.changeFolder(ort.cwd)
        if rt.effectiveEngine == ort.effectiveEngine {
            rt.model = ort.model
            rt.effort = ort.effort
        }
        rt.anko = ort.anko
        if ort.sessionStarted {
            let src = AgentRuntime.ForkSource(session: ort.sessionID, engine: (ort.sessionEngine ?? ort.effectiveEngine).rawValue,
                                              name: c.record.title, cwd: ort.cwd.path)
            rt.setForkSource(src, transcript: transcript(of: ort))
            if rt.effectiveEngine == ort.effectiveEngine { rt.setContext(tokens: ort.contextTokens, window: ort.contextWindow) }
        }
        AppLog.write("tear: agent \(c.record.number) -> \(n.record.number) engine=\(rt.effectiveEngine.rawValue) fork=\(ort.sessionStarted)")
        return n
    }

    /// 分身に渡す会話の写し（AI が違うときだけ使う）
    func transcript(of rt: AgentRuntime) -> String {
        var msgs: [(user: Bool, text: String)] = []
        if let f = rt.sessionFile {
            msgs = ClaudeSessions.messages(in: f, limit: 120).compactMap { m in
                switch m.role {
                case .user: return m.text.hasPrefix(TeamCoordinator.requestMarker) ? nil : (true, m.text)
                case .assistant: return (false, m.text)
                case .tool: return nil
                }
            }
        }
        if msgs.isEmpty {
            for t in rt.turns {
                msgs.append((true, t.prompt))
                if let r = t.result, !r.isEmpty, t.state == .completed { msgs.append((false, r)) }
            }
        }
        return MochiPlay.transcriptText(msgs)
    }

    /// ⌘ を押してドラッグを始めた：分身を引っぱり出す（作業中はちぎれない）
    func tearBegan(_ c: JellyController) -> Bool {
        guard tearState == nil else { return false }
        if runtimes[c.record.id]?.isRunning == true {
            team?.flashHint(on: c, L("作業中のおもちは ちぎれません"))
            NSSound.beep()
            return false
        }
        guard let clone = makeClone(of: c, at: c.panel.frame.origin) else {
            team?.flashHint(on: c, L("おもちは %ld 体までです", TeamCoordinator.maxAgents))
            NSSound.beep()
            return false
        }
        tearState = (c.record.id, clone.record.id)
        clone.show(animated: false)
        clone.avatar.dragBegan()
        c.avatar.dragBegan()
        team?.refresh()
        return true
    }

    func tearDragged(_ c: JellyController, to origin: NSPoint) {
        guard let t = tearState, t.origin == c.record.id, let clone = controller(id: t.clone) else { return }
        clone.panel.setFrameOrigin(origin)
        team?.refresh()
    }

    /// 離した：十分に引っぱっていればちぎれて分身ができる。足りなければ元に戻って消える
    func tearEnded(_ c: JellyController) {
        guard let t = tearState, t.origin == c.record.id, let clone = controller(id: t.clone) else { tearState = nil; return }
        tearState = nil
        c.avatar.dragEnded()
        let d = hypot(clone.anchorPoint.x - c.anchorPoint.x, clone.anchorPoint.y - c.anchorPoint.y)
        if d >= c.panel.frame.width * JellyManager.tearDistance {
            finishTear(c, clone)
        } else {
            // ちぎれなかった：元のおもちに吸い込まれて戻る
            team?.refresh()
            slide([(clone, c.panel.frame.origin)], duration: 0.18) { [weak self] in
                clone.avatar.melt {}
                c.avatar.absorb()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.remove(clone) }
            }
            AppLog.write("tear: cancelled (\(Int(d))pt)")
        }
    }

    private func finishTear(_ c: JellyController, _ clone: JellyController, openChat open: Bool = true) {
        team?.overlay.tearSnap(from: c.anchorPoint, to: clone.anchorPoint)
        clone.avatar.dragEnded()
        clone.update { $0.origin = clone.panel.frame.origin }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            c.avatar.poke()
            clone.avatar.poke()
        }
        save()
        onChange?()
        team?.refresh()
        refreshLook(clone)
        // 分身に、別のやり方を頼めるように
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard open, let self, self.controllers.contains(where: { $0 === clone }) else { return }
            self.openChat(for: clone)
            self.chats[clone.record.id]?.setInputHint(L("✂️ %@ からちぎれた分身です。同じ会話から、別のやり方を頼めます（上の「AI」で、別の AI にもできます）", c.record.title))
        }
    }

    /// メニューから：引っぱってちぎる動きを見せて、隣に分身を作る（engine で AI を変えられる）
    func tearOff(_ c: JellyController, engine: AgentEngine? = nil, openChat open: Bool = true) {
        guard tearState == nil else { return }
        if runtimes[c.record.id]?.isRunning == true {
            team?.flashHint(on: c, L("作業中のおもちは ちぎれません"))
            NSSound.beep()
            return
        }
        let dest = adjacentOrigin(near: c)
        guard let clone = makeClone(of: c, engine: engine, at: c.panel.frame.origin) else { NSSound.beep(); return }
        tearState = (c.record.id, clone.record.id)
        clone.show(animated: false)
        clone.avatar.dragBegan()
        c.avatar.dragBegan()
        slide([(clone, dest)], duration: 0.55, done: { [weak self] in
            guard let self else { return }
            self.tearState = nil
            c.avatar.dragEnded()
            self.finishTear(c, clone, openChat: open)
        }, timing: { t in t * t * (3 - 2 * t) })
    }

    /// ちぎっている途中の糸（TeamCoordinator.refresh が描く）
    func tearPreview() -> LinkOverlay.Tear? {
        guard let t = tearState, let a = controller(id: t.origin), let b = controller(id: t.clone) else { return nil }
        let d = hypot(b.anchorPoint.x - a.anchorPoint.x, b.anchorPoint.y - a.anchorPoint.y)
        return LinkOverlay.Tear(from: a.anchorPoint, to: b.anchorPoint, color: a.record.color.nsColor,
                                ready: d >= a.panel.frame.width * JellyManager.tearDistance)
    }

    func controller(id: UUID) -> JellyController? { controllers.first { $0.record.id == id } }

    // MARK: - くっつく（合体）

    /// おもちを別のおもちに重ねて離した：どうくっつくかを選ぶ
    func dropForMerge(_ a: JellyController, onto b: JellyController) {
        let busy = [a, b].first { runtimes[$0.record.id]?.isRunning == true }
        if let busy {
            team?.flashHint(on: b, L("%@ は作業中なので くっつけません", busy.record.title))
            nudgeAside(a, from: b)
            return
        }
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(.header(L("🍡 %@ と %@ をくっつける", a.record.title, b.record.title)))
        let hasResult = !(lastResult(of: a) ?? "").isEmpty
        let combine = ClosureMenuItem(L("まとめて 1 体に（%@ の結果を %@ が取り込む）", a.record.title, b.record.title)) { [weak self] in
            self?.merge(keep: b, drop: a, combine: true)
        }
        combine.isEnabled = hasResult
        if !hasResult { combine.toolTip = L("%@ にはまだ結果がありません", a.record.title) }
        m.addItem(combine)
        m.addItem(ClosureMenuItem(L("%@ を残す（%@ は溶けて消える）", b.record.title, a.record.title)) { [weak self] in
            self?.merge(keep: b, drop: a, combine: false)
        })
        m.addItem(ClosureMenuItem(L("%@ を残す（%@ は溶けて消える）", a.record.title, b.record.title)) { [weak self] in
            self?.merge(keep: a, drop: b, combine: false)
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("やめる（はなす）")) { [weak self] in self?.nudgeAside(a, from: b) })
        let p = NSPoint(x: b.avatar.anchor.x, y: b.avatar.anchor.y)
        DispatchQueue.main.async {
            // 何も選ばずに閉じたら、はなす
            let chosen = m.popUp(positioning: nil, at: p, in: b.panel.contentView)
            if !chosen, self.controllers.contains(where: { $0 === a }), self.controllers.contains(where: { $0 === b }) { self.nudgeAside(a, from: b) }
        }
    }

    /// 最後の結果（まとめるときに渡す）
    func lastResult(of c: JellyController) -> String? {
        guard let rt = runtimes[c.record.id] else { return nil }
        if let t = rt.turns.last(where: { $0.state == .completed && !($0.result ?? "").isEmpty }) { return t.result }
        if let f = rt.sessionFile { return ClaudeSessions.messages(in: f, limit: 40).last { $0.role == .assistant }?.text }
        return nil
    }

    /// くっつく：drop は keep に溶けて消える。combine なら drop の結果を keep の会話に取り込む。
    /// drop のつながり・鏡餅の部下・あんこ・串の場所は keep が受け継ぐ
    func merge(keep: JellyController, drop: JellyController, combine: Bool, openChat open: Bool = true) {
        guard keep !== drop, let krt = runtimes[keep.record.id], let drt = runtimes[drop.record.id],
              !krt.isRunning, !drt.isRunning else { return }
        let prompt = combine ? lastResult(of: drop).map { MochiPlay.mergePrompt(fromName: drop.record.title, result: $0) } : nil
        let kid = keep.record.id, did = drop.record.id
        // つながり
        if let team {
            for n in team.neighbors(did) where n != kid && !team.isLinked(kid, n) && team.canLink(kid, n) { team.link(kid, n, animated: false) }
        }
        // 鏡餅（drop の部下は keep の部下に。drop がだれかの部下なら keep もそこへ）
        for c in controllers where c.record.leaderID == did && c !== keep { c.update { $0.leaderID = kid } }
        if keep.record.leaderID == nil, let l = drop.record.leaderID, l != kid { keep.update { $0.leaderID = l } }
        if keep.record.leaderID == did { keep.update { $0.leaderID = nil } }
        // あんこ
        var anko = krt.anko
        for p in drt.anko where !anko.contains(p) { anko.append(p) }
        krt.anko = Array(anko.prefix(MochiPlay.maxAnko))
        // 串（drop のいた段に keep が入る。keep がもう同じ串にいれば drop を外すだけ）
        for i in skewers.indices {
            if let j = skewers[i].members.firstIndex(of: did) {
                if skewers[i].members.contains(kid) {
                    skewers[i].members.remove(at: j)
                    if j < skewers[i].steps.count { skewers[i].steps.remove(at: j) }
                } else {
                    skewers[i].members[j] = kid
                }
            }
        }
        saveSkewers()
        AppLog.write("merge: agent \(drop.record.number) into \(keep.record.number) combine=\(prompt != nil)")
        // 溶け合う：drop が keep に寄って平たく溶け、keep がむにっと受け止める
        slide([(drop, keep.panel.frame.origin)], duration: 0.4) { [weak self] in
            guard let self else { return }
            drop.avatar.melt {}
            keep.avatar.absorb()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                self.remove(drop)
                self.refreshAllLooks()
                if let prompt, krt.submit(prompt), open {
                    self.openChat(for: keep)
                }
                self.chats[kid]?.refresh()
            }
        }
    }

    /// 重ねたけれどくっつかない：相手から少し離す
    func nudgeAside(_ a: JellyController, from b: JellyController) {
        let w = a.panel.frame.width
        let pa = a.anchorPoint, pb = b.anchorPoint
        var ang = atan2(pa.y - pb.y, pa.x - pb.x)
        if hypot(pa.x - pb.x, pa.y - pb.y) < 2 { ang = .pi }
        let o = a.panel.frame.origin
        let to = NSPoint(x: pb.x + cos(ang) * w * 1.1 - (pa.x - o.x), y: pb.y + sin(ang) * w * 0.6 - (pa.y - o.y))
        slide([(a, to)], duration: 0.22) { a.avatar.dragEnded() }
    }

    // MARK: - 鏡餅（上に載せる＝リーダー）

    /// top を bottom の上に載せる：top がリーダー、bottom が部下になる（線でもつながる）
    func stack(_ top: JellyController, on bottom: JellyController) {
        guard top !== bottom else { return }
        let tid = top.record.id, bid = bottom.record.id
        if let team, !team.isLinked(tid, bid) {
            guard team.canLink(tid, bid) else {
                team.flashHint(on: bottom, L("チームは %ld 体まで", TeamCoordinator.maxTeamSize))
                nudgeAside(top, from: bottom)
                return
            }
            team.link(tid, bid, animated: false)
        }
        // 上下が入れ替わらないように：bottom が top の上の方（リーダーの系列）にいたら外す
        var cur = top.record.leaderID
        var guardCount = 0
        while let l = cur, guardCount < 32 {
            if l == bid { top.update { $0.leaderID = nil }; break }
            cur = controller(id: l)?.record.leaderID
            guardCount += 1
        }
        bottom.update { $0.leaderID = tid }
        // 同じ串に刺さっていたら、上に載せたほうを串から抜く（串の通った鏡餅にしない）
        if let i = skewers.firstIndex(where: { $0.members.contains(tid) && $0.members.contains(bid) }),
           let j = skewers[i].members.firstIndex(of: tid) {
            skewers[i].members.remove(at: j)
            if j < skewers[i].steps.count { skewers[i].steps.remove(at: j) }
            if skewers[i].members.count < (skewers[i].org ? 1 : 2) { skewers.remove(at: i) }
            saveSkewers()
        }
        AppLog.write("kagami: \(top.record.number) on \(bottom.record.number)")
        arrangeKagami(top)
        refreshAllLooks()
        team?.refresh()
        top.avatar.poke()
    }

    func subordinates(of id: UUID) -> [JellyController] {
        controllers.filter { $0.record.leaderID == id }.sorted { $0.record.number < $1.record.number }
    }

    /// リーダーの下に、部下を横一列に並べる（鏡餅の形。下の段が画面の外に出るなら全体を上げる）
    func arrangeKagami(_ leader: JellyController, animated: Bool = true) {
        let subs = subordinates(of: leader.record.id).filter { !$0.record.hidden }
        guard !subs.isEmpty else { return }
        let P = CGFloat(MochiAvatar.cell(scale: settings.jellyScale))
        let offs = MochiPlay.kagamiOffsets(count: subs.count, cell: P)
        var lo = leader.panel.frame.origin
        let vf = (leader.panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minY = offs.map { lo.y + $0.y }.min() ?? lo.y
        if minY < vf.minY - P { lo.y += vf.minY - P - minY }
        let minX = offs.map { lo.x + $0.x }.min() ?? lo.x, maxX = offs.map { lo.x + $0.x }.max() ?? lo.x
        let w = leader.panel.frame.width
        if minX < vf.minX - w * 0.3 { lo.x += vf.minX - w * 0.3 - minX }
        if maxX + w > vf.maxX + w * 0.3 { lo.x -= maxX + w - vf.maxX - w * 0.3 }
        var moves: [(JellyController, NSPoint)] = [(leader, lo)]
        for (c, o) in zip(subs, offs) { moves.append((c, NSPoint(x: lo.x + o.x, y: lo.y + o.y))) }
        // 上の段（リーダー）が手前に
        slide(moves, duration: animated ? 0.28 : 0) {
            leader.panel.orderFrontRegardless()
        }
        leader.panel.orderFrontRegardless()
    }

    /// 鏡餅をくずす（このおもちの上下の関係をなくす。線のつながりは残す）
    func unstack(_ c: JellyController) {
        var changed = false
        for s in controllers where s.record.leaderID == c.record.id { s.update { $0.leaderID = nil }; changed = true }
        if c.record.leaderID != nil { c.update { $0.leaderID = nil }; changed = true }
        guard changed else { return }
        AppLog.write("kagami: unstack \(c.record.number)")
        refreshAllLooks()
        team?.refresh()
    }

    // MARK: - 動かす（なめらかに置き直す）

    /// おもちを、それぞれの場所へなめらかに動かす（ease-out。動かし終わったら位置を保存）
    func slide(_ moves: [(JellyController, NSPoint)], duration: Double, done: (() -> Void)? = nil, timing: ((Double) -> Double)? = nil) {
        let starts = moves.map { ($0.0, $0.0.panel.frame.origin, $0.1) }
        guard duration > 0 else {
            for (c, _, to) in starts { c.moveTo(to, persist: true) }
            done?()
            return
        }
        let t0 = CACurrentMediaTime()
        let ease = timing ?? { k in 1 - pow(1 - k, 3) }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            let k = min(1, (CACurrentMediaTime() - t0) / duration)
            let e = CGFloat(ease(k))
            for (c, from, to) in starts {
                c.panel.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e))
            }
            self?.team?.refresh()
            if k >= 1 {
                t.invalidate()
                for (c, _, to) in starts { c.moveTo(to, persist: true) }
                done?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - 大福（あんこ）

    /// ファイル・フォルダをおもちに落とした：あんこにする（いつも参照）か、次の指示に添付するかを聞く
    func filesDropped(_ urls: [URL], on c: JellyController) {
        let m = NSMenu()
        m.autoenablesItems = false
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (urls.count > 3 ? L(" ほか %ld 件", urls.count - 3) : "")
        m.addItem(.header(names))
        m.addItem(ClosureMenuItem(L("🫘 あんこにする（大福に：%@ がいつも参照する資料）", c.record.title)) { [weak self] in
            self?.addAnko(urls, to: c)
        })
        m.addItem(ClosureMenuItem(L("📎 次の指示に添付する（今回だけ）")) { [weak self] in self?.attachFiles(urls, to: c) })
        let p = NSPoint(x: c.avatar.anchor.x, y: c.avatar.anchor.y)
        DispatchQueue.main.async { m.popUp(positioning: nil, at: p, in: c.panel.contentView) }
    }

    func addAnko(_ urls: [URL], to c: JellyController) {
        guard let rt = runtimes[c.record.id] else { return }
        var list = rt.anko
        for u in urls {
            let p = u.standardizedFileURL.path
            if !list.contains(p) { list.append(p) }
        }
        if list.count > MochiPlay.maxAnko {
            team?.flashHint(on: c, L("あんこは %ld 個までです", MochiPlay.maxAnko))
            list = Array(list.prefix(MochiPlay.maxAnko))
        }
        rt.anko = list
        c.avatar.absorb()
        refreshLook(c)
        chats[c.record.id]?.refresh()
        AppLog.write("anko: agent \(c.record.number) \(list.count) items")
    }

    func removeAnko(_ path: String, from c: JellyController) {
        guard let rt = runtimes[c.record.id] else { return }
        rt.anko.removeAll { $0 == path }
        refreshLook(c)
        chats[c.record.id]?.refresh()
    }

    func chooseAnko(for c: JellyController) {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = L("あんこにする")
        p.message = L("%@ がいつも参照する資料（ファイル・フォルダ）を選んでください", c.record.title)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { addAnko(p.urls, to: c) }
    }

    // MARK: - 温め直す・焦げを落とす

    /// 温め直す：続きに必要なファイルを読み直してもらう（硬くなった＝しばらく使っていない会話をやわらかく戻す）
    func warmUp(_ c: JellyController) {
        guard let rt = runtimes[c.record.id], rt.sessionStarted, !rt.isRunning else { NSSound.beep(); return }
        let minutes = max(1, Int(Date().timeIntervalSince(rt.lastActiveAt ?? Date()) / 60))
        if rt.submit(MochiPlay.warmPrompt(minutesSince: minutes)) {
            AppLog.write("warm: agent \(c.record.number) after \(minutes) min")
            refreshLook(c)
            chats[c.record.id]?.refresh()
        }
    }

    /// 焦げを落とす：Claude Code の /compact で、会話を要約して軽くする（Claude のおもちだけ）
    func scrapeChar(_ c: JellyController) {
        guard let rt = runtimes[c.record.id], rt.sessionStarted, !rt.isRunning, rt.effectiveEngine == .claude else { NSSound.beep(); return }
        if rt.submit(MochiPlay.compactCommand) {
            AppLog.write("compact: agent \(c.record.number)")
            chats[c.record.id]?.refresh()
        }
    }

    // MARK: - 串だんご

    func saveSkewers() { store.save(skewers, name: "skewers.json") }
    func saveRecipes() { store.save(recipes, name: "recipes.json") }

    func skewer(containing id: UUID) -> Skewer? { skewers.first { $0.members.contains(id) } }

    /// 最初から入っているレシピ（保存したものと並べて出す）
    static var builtinRecipes: [DangoRecipe] { [
        DangoRecipe(id: UUID(uuidString: "6D1A7C2E-0000-4000-8000-000000000001")!, name: L("みたらし（調べる → まとめる）"), steps: [
            DangoStep(title: L("調べる"), instruction: L("次のことを調べて、分かったことを出典つきで箇条書きにしてください。")),
            DangoStep(title: L("まとめる"), instruction: L("前の段の調べた結果を、読みやすい短いまとめにしてください（表があれば表に）。")),
        ]),
        DangoRecipe(id: UUID(uuidString: "6D1A7C2E-0000-4000-8000-000000000002")!, name: L("三色だんご（調べる → まとめる → 確かめる）"), steps: [
            DangoStep(title: L("調べる"), instruction: L("次のことを調べて、分かったことを出典つきで箇条書きにしてください。")),
            DangoStep(title: L("まとめる"), instruction: L("前の段の調べた結果を、読みやすい短いまとめにしてください（表があれば表に）。")),
            DangoStep(title: L("確かめる"), instruction: L("前の段のまとめを確かめてください。誤り・根拠の弱いところ・抜けを挙げ、直した版を出してください。")),
        ]),
    ] }

    var allRecipes: [DangoRecipe] { JellyManager.builtinRecipes + recipes }

    /// おもちを串に刺す（並べ順＝仕事の流れ）。横一列に、体がふれ合うくらいに並べる
    @discardableResult
    func makeSkewer(_ members: [JellyController], steps: [DangoStep], name: String? = nil, org: Bool = false) -> Skewer? {
        guard members.count >= (org ? 1 : 2) else { return nil }
        let ids = members.map(\.record.id)
        // ほかの串からは抜く（1 体は 1 本の串だけ）
        for i in skewers.indices {
            skewers[i].members.removeAll { ids.contains($0) }
        }
        skewers.removeAll { $0.members.count < ($0.org ? 1 : 2) }
        var st = steps
        while st.count < members.count { st.append(DangoStep(title: "")) }
        let s = Skewer(name: name, members: ids, steps: Array(st.prefix(members.count)), org: org)
        skewers.append(s)
        saveSkewers()
        arrangeDango(s)
        AppLog.write("dango: skewer \(members.map { String($0.record.number) }.joined(separator: ">")) org=\(org)")
        return s
    }

    /// 串のおもちを横一列に並べ直す（画面からはみ出すなら左へ寄せる）
    func arrangeDango(_ s: Skewer, animated: Bool = true) {
        let cs = s.members.compactMap { controller(id: $0) }.filter { !$0.record.hidden }
        guard let first = cs.first else { return }
        let P = CGFloat(MochiAvatar.cell(scale: settings.jellyScale))
        let offs = MochiPlay.dangoOffsets(count: cs.count, cell: P)
        var o = first.panel.frame.origin
        let vf = (first.panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = first.panel.frame.width
        let right = o.x + (offs.last?.x ?? 0) + w
        if right > vf.maxX + w * 0.2 { o.x -= right - vf.maxX - w * 0.2 }
        if o.x < vf.minX { o.x = vf.minX }
        slide(zip(cs, offs).map { ($0, NSPoint(x: o.x + $1.x, y: o.y + $1.y)) }, duration: animated ? 0.3 : 0)
    }

    func removeSkewer(_ id: UUID) {
        skewers.removeAll { $0.id == id }
        saveSkewers()
        team?.refresh()
    }

    func updateSkewer(_ s: Skewer) {
        guard let i = skewers.firstIndex(where: { $0.id == s.id }) else { return }
        skewers[i] = s
        saveSkewers()
        team?.refresh()
    }

    /// 串に流す：1 本目に最初のことを渡し、終わったら結果を次の段へ（予約のしくみで、止める・再開もできる）
    @discardableResult
    func runSkewer(_ s: Skewer, input: String) -> String? {
        let cs = s.members.compactMap { controller(id: $0) }
        guard cs.count >= 1, cs.count == s.members.count else { return L("串のおもちが見つかりません") }
        if let busy = cs.dropFirst().first(where: { runtimes[$0.record.id]?.isRunning == true || queues.isActive($0.record.id) }) {
            return L("%@ が作業中です。終わってから流してください", busy.record.title)
        }
        let first = cs[0]
        guard let frt = runtimes[first.record.id] else { return L("串のおもちが見つかりません") }
        let n = cs.count
        let p0 = MochiPlay.dangoStepPrompt(name: s.name, index: 0, count: n, step: s.steps.first ?? DangoStep(title: ""), input: input)
        if frt.isRunning || queues.isActive(first.record.id) {
            queues.enqueue(owner: first.record.id, text: p0)
        } else if !frt.submit(p0) {
            return frt.lastError ?? L("1 本目のおもちが動けませんでした")
        }
        for i in 1..<max(1, n) where i < n {
            queues.enqueue(owner: first.record.id,
                           text: MochiPlay.dangoStepPrompt(name: s.name, index: i, count: n,
                                                           step: i < s.steps.count ? s.steps[i] : DangoStep(title: ""), input: nil),
                           target: cs[i].record.id, passResult: true)
        }
        AppLog.write("dango: run \(n) steps")
        chats[first.record.id]?.refresh()
        team?.refresh()
        return nil
    }

    /// レシピで流す：段ごとに新しいおもちを作って串に刺し、流す
    @discardableResult
    func runRecipe(_ r: DangoRecipe, input: String, near: JellyController? = nil) -> String? {
        guard !r.steps.isEmpty else { return L("段がありません") }
        guard controllers.count + r.steps.count <= TeamCoordinator.maxAgents else { return L("おもちは %ld 体までです", TeamCoordinator.maxAgents) }
        if settings.allHidden { setAllHidden(false) }
        var made: [JellyController] = []
        for st in r.steps {
            var rec = makeRecord()
            rec.name = uniqueName(String((st.title.isEmpty ? L("だんご") : st.title).prefix(24)))
            rec.origin = made.last.map { NSPoint(x: $0.panel.frame.maxX, y: $0.panel.frame.minY) } ?? near.map { adjacentOrigin(near: $0) }
            let c = addController(rec)
            if let e = st.engine.flatMap(AgentEngine.init(rawValue:)), let rt = runtimes[c.record.id] { rt.changeEngine(e) }
            if let base = near, let brt = runtimes[base.record.id] { runtimes[c.record.id]?.changeFolder(brt.cwd) }
            c.show(animated: true)
            made.append(c)
        }
        save()
        onChange?()
        guard let s = makeSkewer(made, steps: r.steps, name: r.name) else { return L("串を作れませんでした") }
        return runSkewer(s, input: input)
    }

    func saveRecipe(name: String, from s: Skewer) {
        let steps = s.members.enumerated().map { i, id -> DangoStep in
            var st = i < s.steps.count ? s.steps[i] : DangoStep(title: "")
            if st.engine == nil, let rt = runtimes[id], rt.engine != nil { st.engine = rt.effectiveEngine.rawValue }
            return st
        }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = recipes.firstIndex(where: { $0.name == n }) { recipes[i].steps = steps } else { recipes.append(DangoRecipe(name: n, steps: steps)) }
        saveRecipes()
        AppLog.write("dango: recipe saved (\(steps.count) steps)")
    }

    func deleteRecipe(_ id: UUID) {
        recipes.removeAll { $0.id == id }
        saveRecipes()
    }

    /// 串の見た目（TeamCoordinator.refresh が描く）
    func skewerSticks() -> [LinkOverlay.Stick] {
        guard !settings.allHidden else { return [] }
        return skewers.compactMap { s in
            let pts = s.members.compactMap { controller(id: $0) }.filter(\.isVisible).map(\.anchorPoint)
            return pts.count >= 2 ? LinkOverlay.Stick(id: s.id, points: pts) : nil
        }
    }

    /// 串の段の名前（名前ラベルに添える）
    func skewerStepLabel(_ id: UUID) -> String? {
        guard let s = skewer(containing: id), let i = s.members.firstIndex(of: id) else { return nil }
        let t = i < s.steps.count ? s.steps[i].title.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return "\(i + 1)" + (t.isEmpty ? "" : " " + t)
    }

    func showDango(for c: JellyController? = nil, recipe: DangoRecipe? = nil) {
        let w = dangoWindow ?? DangoWindowController(manager: self)
        dangoWindow = w
        w.show(start: c, recipe: recipe)
    }

    func showMaki(from c: JellyController? = nil) {
        let w = makiWindow ?? MochiMakiWindowController(manager: self)
        makiWindow = w
        w.show(from: c)
    }

    // MARK: - おもちごとのメニュー（右クリック）

    func mochiMenuItems(for c: JellyController) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let id = c.record.id
        let rt = runtimes[id]
        let running = rt?.isRunning ?? false
        // ✂️ ちぎる
        let tear = NSMenuItem(title: L("✂️ ちぎる（同じ会話の分身を作る）"), action: nil, keyEquivalent: "")
        let tm = NSMenu()
        tm.autoenablesItems = false
        let mine = rt?.effectiveEngine ?? settings.engine
        tm.addItem(ClosureMenuItem(L("同じ AI（%@）で", mine.displayName)) { [weak self, weak c] in if let c { self?.tearOff(c) } })
        for e in AgentEngine.allCases where e != mine {
            tm.addItem(ClosureMenuItem(L("%@ で（会話を渡して別の AI に試させる）", e.displayName)) { [weak self, weak c] in if let c { self?.tearOff(c, engine: e) } })
        }
        tm.addItem(.separator())
        tm.addItem(.header(L("⌘ を押しながら引っぱっても ちぎれます")))
        tear.submenu = tm
        tear.isEnabled = !running
        items.append(tear)
        // 🍡 くっつく
        let others = controllers.filter { $0 !== c && !$0.record.hidden }
        if !others.isEmpty {
            let mi = NSMenuItem(title: L("🍡 くっつく"), action: nil, keyEquivalent: "")
            let mm = NSMenu()
            mm.autoenablesItems = false
            for o in others.sorted(by: { $0.record.number < $1.record.number }) {
                let it = ClosureMenuItem(L("%@ にくっつく…", o.record.title), image: MenuImages.dot(o.record.color, state: o.record.state)) { [weak self, weak c, weak o] in
                    if let c, let o { self?.dropForMerge(c, onto: o) }
                }
                it.isEnabled = !running && runtimes[o.record.id]?.isRunning != true
                mm.addItem(it)
            }
            mm.addItem(.separator())
            mm.addItem(.header(L("重ねて離しても くっつきます")))
            mi.submenu = mm
            items.append(mi)
        }
        // 🍊 鏡餅
        let subs = subordinates(of: id)
        if !others.isEmpty {
            let ki = NSMenuItem(title: L("🍊 鏡餅"), action: nil, keyEquivalent: "")
            let km = NSMenu()
            km.autoenablesItems = false
            for o in others.sorted(by: { $0.record.number < $1.record.number }) where o.record.leaderID != id {
                km.addItem(ClosureMenuItem(L("%@ の上に載る（リーダーになる）", o.record.title), image: MenuImages.dot(o.record.color, state: o.record.state)) { [weak self, weak c, weak o] in
                    if let c, let o { self?.stack(c, on: o) }
                })
            }
            if !subs.isEmpty || c.record.leaderID != nil {
                km.addItem(.separator())
                if !subs.isEmpty {
                    km.addItem(.header(L("部下: %@", subs.map(\.record.title).joined(separator: L("・")))))
                    km.addItem(ClosureMenuItem(L("鏡餅の形に並べ直す")) { [weak self, weak c] in if let c { self?.arrangeKagami(c) } })
                }
                if let l = c.record.leaderID.flatMap({ controller(id: $0) }) { km.addItem(.header(L("リーダー: %@", l.record.title))) }
                km.addItem(ClosureMenuItem(L("鏡餅をくずす（線のつながりは残す）")) { [weak self, weak c] in if let c { self?.unstack(c) } })
            }
            km.addItem(.separator())
            km.addItem(.header(L("頭の上に載せて離しても 鏡餅になります")))
            ki.submenu = km
            items.append(ki)
        }
        // 🍡 串だんご
        let di = NSMenuItem(title: L("🍡 串だんご"), action: nil, keyEquivalent: "")
        let dm = NSMenu()
        dm.autoenablesItems = false
        if let s = skewer(containing: id) {
            dm.addItem(.header(L("串: %@", s.members.compactMap { controller(id: $0)?.record.title }.joined(separator: " → "))))
            if !s.org {
                dm.addItem(ClosureMenuItem(L("▶ 串に流す…")) { [weak self, weak c] in self?.showDango(for: c) })
                dm.addItem(ClosureMenuItem(L("並べ直す")) { [weak self] in self?.arrangeDango(s) })
            }
            dm.addItem(ClosureMenuItem(L("串から抜く")) { [weak self] in
                guard let self, var cur = self.skewer(containing: id), let i = cur.members.firstIndex(of: id) else { return }
                cur.members.remove(at: i)
                if i < cur.steps.count { cur.steps.remove(at: i) }
                if cur.members.count < 2 { self.removeSkewer(cur.id) } else { self.updateSkewer(cur) }
            })
            dm.addItem(ClosureMenuItem(L("串をはずす（おもちはそのまま）")) { [weak self] in self?.removeSkewer(s.id) })
        } else {
            dm.addItem(ClosureMenuItem(L("このおもちから串を作る…")) { [weak self, weak c] in self?.showDango(for: c) })
            for s in skewers where !s.org {
                let names = s.members.compactMap { controller(id: $0)?.record.title }.joined(separator: " → ")
                dm.addItem(ClosureMenuItem(L("串「%@」の最後に刺す", names)) { [weak self, weak c] in
                    guard let self, let c, var cur = self.skewers.first(where: { $0.id == s.id }) else { return }
                    cur.members.append(c.record.id)
                    cur.steps.append(DangoStep(title: ""))
                    self.updateSkewer(cur)
                    self.arrangeDango(cur)
                })
            }
        }
        di.submenu = dm
        items.append(di)
        // 🫘 あんこ（大福）
        let ai = NSMenuItem(title: rt.map { $0.anko.isEmpty ? L("🫘 あんこ（大福にする）") : L("🫘 あんこ（%ld）", $0.anko.count) } ?? L("🫘 あんこ"), action: nil, keyEquivalent: "")
        let am = NSMenu()
        am.autoenablesItems = false
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in rt?.anko ?? [] {
            am.addItem(ClosureMenuItem(L("✕ %@ を外す", p.replacingOccurrences(of: home, with: "~"))) { [weak self, weak c] in
                if let c { self?.removeAnko(p, from: c) }
            })
        }
        if !(rt?.anko.isEmpty ?? true) { am.addItem(.separator()) }
        am.addItem(ClosureMenuItem(L("あんこを足す…")) { [weak self, weak c] in if let c { self?.chooseAnko(for: c) } })
        am.addItem(.header(L("ファイルやフォルダをおもちに落としても 包めます")))
        ai.submenu = am
        items.append(ai)
        // ♨️ 温め直す・🧽 焦げを落とす
        if let rt, rt.sessionStarted {
            let hard = MochiPlay.hardness(lastActive: rt.lastActiveAt)
            let warm = ClosureMenuItem(hard > 0 ? L("♨️ 温め直す（硬くなっています）") : L("♨️ 温め直す")) { [weak self, weak c] in if let c { self?.warmUp(c) } }
            warm.isEnabled = !running
            items.append(warm)
            let ratio = MochiPlay.contextRatio(tokens: rt.contextTokens, window: rt.contextWindow)
            if rt.effectiveEngine == .claude, ratio > 0 {
                let pct = Int((ratio * 100).rounded())
                let cut = ClosureMenuItem(L("🧽 焦げを落とす（会話を要約して軽くする・いま %ld%%）", pct)) { [weak self, weak c] in if let c { self?.scrapeChar(c) } }
                cut.isEnabled = !running
                items.append(cut)
            }
        }
        return items
    }

    /// omochi://debug 用：分身・鏡餅・串・あんこ・会話の大きさ
    func debugMochiLines() -> [String] {
        var out: [String] = []
        for c in controllers {
            guard let rt = runtimes[c.record.id] else { continue }
            var parts: [String] = []
            if let f = rt.forkSource { parts.append("fork=\(f.name)/\(f.engine)") }
            if let l = c.record.leaderID.flatMap({ controller(id: $0) }) { parts.append("leader=\(l.record.number)") }
            if !rt.anko.isEmpty { parts.append("anko=\(rt.anko.count)") }
            if let t = rt.contextTokens { parts.append("context=\(t)/\(rt.contextWindow ?? 0)") }
            parts.append("session=\(rt.sessionID.prefix(8))\(rt.sessionStarted ? "" : "(new)")")
            out.append("mochi \(c.record.number) " + parts.joined(separator: " "))
        }
        for s in skewers {
            out.append("skewer \(s.org ? "org " : "")" + s.members.compactMap { controller(id: $0).map { String($0.record.number) } }.joined(separator: ">"))
        }
        return out
    }

    /// デモの録画用：見えているおもちの上から、お餅を投げる動きだけ（何も送らない）
    func demoToss() {
        let vis = controllers.filter(\.isVisible)
        guard !vis.isEmpty else { return }
        let xs = vis.map(\.anchorPoint.x)
        let top = (vis.map(\.panel.frame.maxY).max() ?? 0) + 160
        team?.overlay.throwPieces(from: CGPoint(x: (xs.min()! + xs.max()!) / 2, y: top),
                                  to: vis.map { ($0.anchorPoint, $0.record.color.nsColor) })
        for (i, c) in vis.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 + Double(i) * 0.09) { c.avatar.absorb() }
        }
    }
}
