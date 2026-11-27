import AppKit

extension JellyColor {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(flat.x), green: CGFloat(flat.y), blue: CGFloat(flat.z), alpha: 1) }
}

/// おもち同士の「お餅の糸」・名前ラベル・受け渡しの塊を描く、画面全体の透明な重ね窓（クリックは素通し）。
/// - つながりは、引っぱったお餅の糸。離すほど細くなり（まん中がくびれる）、ひまなときはゆるく垂れ、
///   仕事が流れている・詰まっているときはぴんと張る
/// - 依頼を出すと依頼元の色の塊が、結果が返ると依頼先の色の塊が、糸の中を流れて相手へ届く
/// - 糸の近くにポインタを置くと ✂︎ が出て、クリックで切れる
/// - ちぎる（⌘ ドラッグ）ときの、のびてくびれる糸と、ぷちっと切れる動き
/// - 串だんごの串、餅まきで飛んでいくお餅
/// 静止中はアニメーションが無いので CPU を使わない
final class LinkOverlay {
    struct Label { let id: UUID; let text: String; let at: CGPoint; let color: NSColor }
    /// ドラッグ中の「離すと〜」の表示：つながる（相手まで細い糸と輪）・くっつく（相手を囲む輪）・上に載る（相手の頭の上の輪）
    enum PreviewKind { case link, merge, stack }
    struct Preview {
        let from: CGPoint; let to: CGPoint; let color: NSColor; let ok: Bool; let radius: CGFloat
        var kind: PreviewKind = .link
    }
    /// 操作のヒント（at は吹き出しの上端中央）
    struct Pill { let id: String; let text: String; let at: CGPoint; let color: NSColor }
    /// 串だんごの串（おもちの中心を左から順に）
    struct Stick { let id: UUID; let points: [CGPoint] }
    /// ちぎっている途中の糸（ready = 離すとちぎれる）
    struct Tear { let from: CGPoint; let to: CGPoint; let color: NSColor; let ready: Bool }
    static let warnColor = NSColor(srgbRed: 1, green: 0.42, blue: 0.38, alpha: 0.95)
    /// お餅の糸の色（白いお餅）
    static let mochiColor = NSColor(srgbRed: 0.97, green: 0.955, blue: 0.925, alpha: 0.96)

    var onCut: ((JellyLink) -> Void)?

    private var windows: [OverlayWindow] = []
    /// 糸の形（スクリーン座標）：両端・垂れ・太さ
    private var geometry: [JellyLink: StringShape] = [:]
    private var order: [JellyLink] = []
    private var flows: [JellyLink: (toward: UUID, color: NSColor)] = [:]
    /// ⌥ ドラッグで「離すと切れる」状態の線
    private var warn: Set<JellyLink> = []
    private var hasContent = false
    private var packetsInFlight = 0
    private let scissors = ScissorsPanel()
    private var scissorsLink: JellyLink?
    private var scissorsAt: CGPoint = .zero
    /// デモ用に ✂︎ を固定表示している間はポインタ追跡で消さない
    private var scissorsPinned = false
    /// 体の幅（pt）。糸の太さの目安
    private var bodyWidth: CGFloat = 100

    /// 最後に描いた内容（スクリーン座標）。ディスプレイが変わって窓を作り直したときや、
    /// 表示を確かめ直すときに、次の update を待たずにそのまま描き直す
    private struct Content {
        var labels: [Label] = []
        var preview: Preview?
        var pills: [Pill] = []
        var sticks: [Stick] = []
        var tear: Tear?
    }
    private var content = Content()

    init() {
        scissors.onClick = { [weak self] in
            guard let self, let l = self.scissorsLink else { return }
            self.hideScissors()
            self.onCut?(l)
        }
    }

    // MARK: - 糸の形

    /// お餅の糸 1 本の形。a・b は両端、sag は垂れ（pt、下へ）、end は端の太さ、neck はまん中の太さの割合
    struct StringShape: Equatable {
        var a: CGPoint
        var b: CGPoint
        var sag: CGFloat
        var end: CGFloat
        var neck: CGFloat

        var control: CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 2 * sag)
        }

        func point(_ t: CGFloat) -> CGPoint {
            let c = control, u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }

        /// t での太さ（両端は end、まん中は end × neck）
        func width(_ t: CGFloat) -> CGFloat { end * (1 - (1 - neck) * sin(.pi * t)) }

        /// 中心線（✂︎ の判定と、塊を流す道）
        func centerPath(reversed: Bool = false) -> CGPath {
            let p = CGMutablePath()
            p.move(to: reversed ? b : a)
            p.addQuadCurve(to: reversed ? a : b, control: control)
            return p
        }

        /// 太さの変わる糸の輪郭（塗りつぶす形）
        func outline(scale: CGFloat = 1, offsetY: CGFloat = 0) -> CGPath {
            let n = 28
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let p = point(t)
                let q = point(min(1, t + 0.01)), r = point(max(0, t - 0.01))
                var dx = q.x - r.x, dy = q.y - r.y
                let l = max(0.0001, hypot(dx, dy))
                dx /= l; dy /= l
                let w = width(t) * scale / 2
                left.append(CGPoint(x: p.x - dy * w, y: p.y + dx * w + offsetY))
                right.append(CGPoint(x: p.x + dy * w, y: p.y - dx * w + offsetY))
            }
            let path = CGMutablePath()
            path.move(to: left[0])
            for p in left.dropFirst() { path.addLine(to: p) }
            // 端は丸く
            let endR = max(0.5, width(1) * scale / 2)
            path.addArc(center: CGPoint(x: b.x, y: b.y + offsetY), radius: endR,
                        startAngle: atan2(left[n].y - b.y - offsetY, left[n].x - b.x),
                        endAngle: atan2(right[n].y - b.y - offsetY, right[n].x - b.x), clockwise: true)
            for p in right.reversed() { path.addLine(to: p) }
            let startR = max(0.5, width(0) * scale / 2)
            path.addArc(center: CGPoint(x: a.x, y: a.y + offsetY), radius: startR,
                        startAngle: atan2(right[0].y - a.y - offsetY, right[0].x - a.x),
                        endAngle: atan2(left[0].y - a.y - offsetY, left[0].x - a.x), clockwise: true)
            path.closeSubpath()
            return path
        }

        func moved(by o: CGPoint) -> StringShape {
            StringShape(a: CGPoint(x: a.x - o.x, y: a.y - o.y), b: CGPoint(x: b.x - o.x, y: b.y - o.y), sag: sag, end: end, neck: neck)
        }
    }

    /// 2 体のあいだの糸の形：離すほど細く・まん中がくびれる。ひまなら垂れ、張っていればまっすぐ
    static func shape(_ a: CGPoint, _ b: CGPoint, taut: Bool, body w: CGFloat) -> StringShape {
        let len = hypot(b.x - a.x, b.y - a.y)
        let rest = w * TeamCoordinator.settleDistance
        let end = max(2.6, min(w * 0.085, w * 0.085 * pow(rest / max(len, 1), 0.35)))
        let neck = max(0.32, min(0.92, pow(rest / max(len, 1), 0.8)))
        let sag = taut ? 0 : min(len * 0.14, w * 0.42)
        return StringShape(a: a, b: b, sag: sag, end: taut ? end * 0.85 : end, neck: taut ? max(0.3, neck * 0.85) : neck)
    }

    // MARK: - 描画の更新

    func update(segments: [(JellyLink, CGPoint, CGPoint)], labels: [Label], preview: Preview?,
                pills: [Pill] = [], warn: Set<JellyLink> = [], taut: Set<JellyLink> = [], bodyWidth: CGFloat = 100,
                sticks: [Stick] = [], tear: Tear? = nil) {
        self.bodyWidth = bodyWidth
        var g: [JellyLink: StringShape] = [:]
        for (l, a, b) in segments { g[l] = LinkOverlay.shape(a, b, taut: taut.contains(l) || flows[l] != nil, body: bodyWidth) }
        geometry = g
        order = segments.map(\.0)
        self.warn = warn
        content = Content(labels: labels, preview: preview, pills: pills, sticks: sticks, tear: tear)
        hasContent = !segments.isEmpty || !labels.isEmpty || preview != nil || !pills.isEmpty || !sticks.isEmpty || tear != nil
        // 窓を作り直したときは syncWindows の中で描き直している
        if !syncWindows() { draw(windows) }
        updateVisibility()
        if let l = scissorsLink, geometry[l] == nil { hideScissors() }
    }

    /// いまの内容（糸・名前・串・ヒントなど）を窓に描く
    private func draw(_ targets: [OverlayWindow]) {
        guard !targets.isEmpty else { return }
        let c = content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in targets {
            let o = w.frame.origin
            w.setSticks(c.sticks.map { Stick(id: $0.id, points: $0.points.map(w.local)) }, bodyWidth: bodyWidth)
            w.setStrings(order.compactMap { l in geometry[l].map { (l, $0.moved(by: o)) } },
                         styler: { [weak self] l, layer in self?.style(layer, l) })
            w.setLabels(c.labels.map { Label(id: $0.id, text: $0.text, at: w.local($0.at), color: $0.color) })
            w.setPreview(c.preview.map { Preview(from: w.local($0.from), to: w.local($0.to), color: $0.color, ok: $0.ok, radius: $0.radius, kind: $0.kind) },
                         bodyWidth: bodyWidth)
            w.setPills(c.pills.map { Pill(id: $0.id, text: $0.text, at: w.local($0.at), color: $0.color) })
            w.setTear(c.tear.map { Tear(from: w.local($0.from), to: w.local($0.to), color: $0.color, ready: $0.ready) }, bodyWidth: bodyWidth)
        }
        CATransaction.commit()
    }

    private func style(_ layer: StringLayer, _ l: JellyLink) {
        if l == scissorsLink || warn.contains(l) {
            layer.setColors(body: LinkOverlay.warnColor, shine: NSColor(white: 1, alpha: 0.35))
            layer.setLump(nil)
        } else if let f = flows[l] {
            // 仕事が流れている：糸に依頼元の色がうっすら移り、塊がくり返し流れる
            let body = LinkOverlay.mochiColor.blended(withFraction: 0.32, of: f.color) ?? LinkOverlay.mochiColor
            layer.setColors(body: body, shine: NSColor(white: 1, alpha: 0.6))
            layer.setLump((color: f.color, forward: f.toward == l.b))
        } else {
            layer.setColors(body: LinkOverlay.mochiColor, shine: NSColor(white: 1, alpha: 0.7))
            layer.setLump(nil)
        }
    }

    func setFlow(_ l: JellyLink, toward: UUID?, color: NSColor) {
        if let t = toward { flows[l] = (t, color) } else { flows[l] = nil }
        if let s = geometry[l] {
            // 張る・ゆるむ
            geometry[l] = LinkOverlay.shape(s.a, s.b, taut: toward != nil, body: bodyWidth)
            for w in windows { w.reshape(l, geometry[l]!.moved(by: w.frame.origin)) }
        }
        restyle()
    }

    private func restyle() {
        for w in windows { w.restyle { [weak self] l, layer in self?.style(layer, l) } }
    }

    // MARK: - 受け渡しの塊

    /// 点の列（おもちの中心を線の順に）に沿って、糸の中をお餅の塊が流れる
    func sendPackets(along points: [CGPoint], color: NSColor) {
        guard points.count > 1 else { return }
        syncWindows()
        // 糸の形に沿う道（いまの糸があればその垂れ方で）
        let path = CGMutablePath()
        path.move(to: points[0])
        var length: CGFloat = 0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            length += hypot(b.x - a.x, b.y - a.y)
            let s = geometry.values.first { ($0.a.dist(a) < 2 && $0.b.dist(b) < 2) || ($0.a.dist(b) < 2 && $0.b.dist(a) < 2) }
            let sag = s?.sag ?? 0
            path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 2 * sag))
        }
        let duration = max(0.55, Double(length / 420))
        packetsInFlight += 1
        updateVisibility()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.packetsInFlight -= 1
            self.updateVisibility()
        }
        for w in windows where w.intersects(points) {
            var t = CGAffineTransform(translationX: -w.frame.minX, y: -w.frame.minY)
            guard let local = path.copy(using: &t) else { continue }
            w.addLump(along: local, color: color, size: max(9, bodyWidth * 0.13), duration: duration, delay: 0)
            w.addLump(along: local, color: color, size: max(6, bodyWidth * 0.08), duration: duration, delay: 0.16)
        }
        CATransaction.commit()
    }

    /// つながったとき：糸がのびて届き、白い塊が 1 つ流れる
    func linkCreated(_ l: JellyLink, from p1: CGPoint, to p2: CGPoint) {
        for w in windows { w.animateDraw(l) }
        sendPackets(along: [p1, p2], color: NSColor(white: 1, alpha: 1))
    }

    /// 切ったとき：まん中から左右に縮んで消える
    func linkCut(from p1: CGPoint, to p2: CGPoint) {
        snap(p1, p2, color: LinkOverlay.warnColor)
    }

    /// ちぎれたとき：くびれから、ぷちっと両側へ縮む（白いお餅の糸）
    func tearSnap(from p1: CGPoint, to p2: CGPoint) {
        snap(p1, p2, color: LinkOverlay.mochiColor)
    }

    private func snap(_ p1: CGPoint, _ p2: CGPoint, color: NSColor) {
        syncWindows()
        packetsInFlight += 1
        updateVisibility()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.packetsInFlight -= 1
            self?.updateVisibility()
        }
        for w in windows where w.intersects([p1, p2]) { w.addSnap(w.local(p1), w.local(p2), color: color, width: max(3, bodyWidth * 0.06)) }
        CATransaction.commit()
    }

    /// 餅まき：from から、それぞれの相手へお餅が弧を描いて飛ぶ（落ちたら相手がぷくっと受け止める）
    func throwPieces(from: CGPoint, to targets: [(CGPoint, NSColor)], duration: Double = 0.7) {
        guard !targets.isEmpty else { return }
        syncWindows()
        packetsInFlight += 1
        updateVisibility()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.packetsInFlight -= 1
            self?.updateVisibility()
        }
        for (i, (p, color)) in targets.enumerated() {
            let top = max(from.y, p.y) + max(80, abs(p.x - from.x) * 0.45)
            let path = CGMutablePath()
            path.move(to: from)
            path.addQuadCurve(to: p, control: CGPoint(x: (from.x + p.x) / 2, y: top))
            for w in windows where w.intersects([from, p, CGPoint(x: (from.x + p.x) / 2, y: top)]) {
                var t = CGAffineTransform(translationX: -w.frame.minX, y: -w.frame.minY)
                guard let local = path.copy(using: &t) else { continue }
                w.addPiece(along: local, color: color, size: max(12, bodyWidth * 0.2), duration: duration, delay: Double(i) * 0.09)
            }
        }
        CATransaction.commit()
    }

    // MARK: - ✂︎

    func pointerMoved(_ p: CGPoint) {
        if scissorsPinned { return }
        if scissors.isVisible, hypot(p.x - scissorsAt.x, p.y - scissorsAt.y) < 18 { return }
        var best: (JellyLink, CGPoint, CGFloat)?
        for l in order {
            guard let s = geometry[l] else { continue }
            let len = hypot(s.b.x - s.a.x, s.b.y - s.a.y)
            // おもち本体の近く（両端）は除く。糸の中心線を細かく区切って近さを見る
            guard len > 70 else { continue }
            let n = 16
            for i in 0..<n {
                let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n)
                let (q, d, t) = LinkOverlay.project(p, s.point(t0), s.point(t1))
                let tt = t0 + (t1 - t0) * t
                guard tt * len > 34, (1 - tt) * len > 34 else { continue }
                if d < 12, d < (best?.2 ?? .infinity) { best = (l, q, d) }
            }
        }
        guard let (l, q, _) = best else { hideScissors(); return }
        scissorsAt = q
        if scissorsLink != l { scissorsLink = l; restyle() }
        scissors.show(at: q)
    }

    func showScissors(_ l: JellyLink, at p: CGPoint) {
        let q = geometry[l]?.point(0.5) ?? p
        scissorsAt = q
        scissorsLink = l
        scissorsPinned = true
        restyle()
        scissors.show(at: q)
    }

    func hideScissors() {
        scissorsPinned = false
        guard scissors.isVisible || scissorsLink != nil else { return }
        scissors.orderOut(nil)
        if scissorsLink != nil { scissorsLink = nil; restyle() }
    }

    static func project(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGFloat, CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = max(dx * dx + dy * dy, 0.0001)
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return (q, hypot(p.x - q.x, p.y - q.y), t)
    }

    // MARK: - 窓（ディスプレイごと）

    /// ディスプレイ 1 枚に重ね窓 1 枚をそろえる。窓はできるだけ使い回し（大きさ・位置・倍率だけ合わせる）、
    /// 足りなければ作り、余れば片付ける。変えた窓には最後の内容をすぐ描き直す。
    /// （前は枠が少しでも違うと全部作り直し、描き直しは次の update まで待っていたので、
    ///   その間に塊を流す・ちぎるなどが先に来ると、糸も名前も無い窓が前に出たままになっていた）
    /// - Returns: 窓を変えたか
    @discardableResult
    private func syncWindows() -> Bool {
        let screens = NSScreen.screens
        var touched: [OverlayWindow] = []
        while windows.count > screens.count {
            let w = windows.removeLast()
            w.orderOut(nil)
            w.close()
        }
        for (i, s) in screens.enumerated() {
            if i < windows.count {
                let w = windows[i]
                if w.scale != s.backingScaleFactor {
                    // 倍率が変わった（Retina と普通の画面の入れ替えなど）：文字や線をその倍率で描き直すため作り直す
                    w.orderOut(nil)
                    w.close()
                    windows[i] = OverlayWindow.make(for: s)
                    touched.append(windows[i])
                } else if !w.frame.isAbout(s.frame) {
                    w.fit(to: s.frame)
                    touched.append(w)
                }
            } else {
                windows.append(OverlayWindow.make(for: s))
                touched.append(windows[windows.count - 1])
            }
        }
        guard !touched.isEmpty else { return false }
        draw(touched)
        updateVisibility()
        return true
    }

    private var shouldShow: Bool { hasContent || packetsInFlight > 0 }

    private func updateVisibility() {
        let show = shouldShow
        for w in windows {
            if show && !w.isVisible { w.orderFrontRegardless() }
            if !show && w.isVisible { w.orderOut(nil) }
        }
    }

    /// 表示を確かめ直す（スペースの切り替え・スリープ明け・ディスプレイの変化のあとと、ときどき）。
    /// 描くものがあるのに画面に出ていない窓（onScreen が false を返すもの）は、前に出し直して描き直す。
    /// - Parameter onScreen: その窓がいま画面に出ているか（WindowServer に聞く。テストでは差し替える）
    /// - Returns: 新しく出し直した窓の数（消灯中のディスプレイなど、出し直しても出ないままの窓は 2 回目から数えない）
    @discardableResult
    func reassert(onScreen: (NSWindow) -> Bool) -> Int {
        syncWindows()
        guard shouldShow else {
            for w in windows where w.isVisible { w.orderOut(nil) }
            lostBefore = []
            return 0
        }
        let lost = windows.filter { !$0.isVisible || !onScreen($0) }
        let ids = Set(lost.map(ObjectIdentifier.init))
        defer { lostBefore = ids }
        guard !lost.isEmpty else { return 0 }
        for w in lost { w.orderFrontRegardless() }
        draw(lost)
        return ids.subtracting(lostBefore).count
    }
    private var lostBefore: Set<ObjectIdentifier> = []

    /// 試験用（omochi://debug?lose=strings）：糸の窓を、知らせずに画面から下ろす（見張りが戻すかを確かめる）
    func debugLose() { windows.forEach { $0.orderOut(nil) } }

    /// omochi://debug 用：重ね窓の状態
    func debugLines(onScreen: (NSWindow) -> Bool) -> [String] {
        ["overlay content=\(hasContent) packets=\(packetsInFlight) strings=\(order.count) windows=\(windows.count) preview=\(content.preview.map { "\($0.kind)" } ?? "-") pills=\(content.pills.map(\.text).joined(separator: " / "))"]
            + windows.enumerated().map { i, w in
                "overlay window \(i) frame=\(w.frame) visible=\(w.isVisible) onScreen=\(onScreen(w)) activeSpace=\(w.isOnActiveSpace) strings=\(w.stringCount)"
            }
    }
}

private extension CGRect {
    /// 窓の枠はピクセルに丸められることがあるので、1pt 未満の違いは同じとみなす
    func isAbout(_ o: CGRect) -> Bool {
        abs(minX - o.minX) < 1 && abs(minY - o.minY) < 1 && abs(width - o.width) < 1 && abs(height - o.height) < 1
    }
}

private extension CGPoint {
    func dist(_ o: CGPoint) -> CGFloat { hypot(x - o.x, y - o.y) }
}

/// お餅の糸 1 本（塗りの体・上の照り・流れる塊）
final class StringLayer: CALayer {
    let body = CAShapeLayer()
    let shine = CAShapeLayer()
    private let lump = CAShapeLayer()
    private var lumpSpec: (color: NSColor, forward: Bool)?
    private(set) var shape: LinkOverlay.StringShape?

    override init() {
        super.init()
        for s in [body, shine] {
            s.lineWidth = 0
            s.actions = ["path": NSNull(), "fillColor": NSNull()]
            addSublayer(s)
        }
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.32
        body.shadowRadius = 1.8
        body.shadowOffset = CGSize(width: 0, height: -0.8)
        lump.isHidden = true
        lump.actions = ["path": NSNull(), "fillColor": NSNull(), "position": NSNull(), "hidden": NSNull()]
        lump.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
        lump.lineWidth = 1
        addSublayer(lump)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// 中の形も同じ倍率で描く（Retina でにじまないように）
    override var contentsScale: CGFloat {
        didSet { for s in [body, shine, lump] { s.contentsScale = contentsScale } }
    }

    func setShape(_ s: LinkOverlay.StringShape) {
        let changed = shape.map { $0.a.distance(to: s.a) > 0.5 || $0.b.distance(to: s.b) > 0.5 || abs($0.sag - s.sag) > 0.5 } ?? true
        shape = s
        body.path = s.outline()
        // 照り：上側に細く
        shine.path = s.outline(scale: 0.32, offsetY: s.end * 0.18)
        if changed, let spec = lumpSpec { startLump(spec) }
    }

    func setColors(body b: NSColor, shine sh: NSColor) {
        body.fillColor = b.cgColor
        shine.fillColor = sh.cgColor
    }

    /// 流れる塊（nil で止める）。道が変わったときも流し直す
    func setLump(_ spec: (color: NSColor, forward: Bool)?) {
        let same = lumpSpec.map { a in spec.map { a.color == $0.color && a.forward == $0.forward } ?? false } ?? (spec == nil)
        lumpSpec = spec
        guard !same else { return }
        if let spec { startLump(spec) } else { lump.removeAllAnimations(); lump.isHidden = true }
    }

    private func startLump(_ spec: (color: NSColor, forward: Bool)) {
        guard let s = shape else { return }
        let d = max(7, s.end * 1.9)
        lump.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
        lump.fillColor = spec.color.cgColor
        lump.isHidden = false
        lump.removeAllAnimations()
        let a = CAKeyframeAnimation(keyPath: "position")
        a.path = s.centerPath(reversed: !spec.forward)
        a.calculationMode = .paced
        a.duration = max(0.9, Double(hypot(s.b.x - s.a.x, s.b.y - s.a.y) / 160))
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.85, 1]
        fade.duration = a.duration
        fade.repeatCount = .infinity
        lump.add(a, forKey: "flow")
        lump.add(fade, forKey: "fade")
    }
}

private extension CGPoint {
    func distance(to o: CGPoint) -> CGFloat { hypot(x - o.x, y - o.y) }
}

/// ディスプレイ 1 枚ぶんの透明な重ね窓
private final class OverlayWindow: NSPanel {
    private let root = CALayer()
    private let stickRoot = CALayer()
    private let stringRoot = CALayer()
    private var lines: [JellyLink: StringLayer] = [:]
    private var sticks: [UUID: CAShapeLayer] = [:]
    private var labels: [UUID: CALayer] = [:]
    private var pills: [String: CALayer] = [:]
    private let previewLayer = StringLayer()
    private let ringLayer = CAShapeLayer()
    private let tearLayer = StringLayer()
    let scale: CGFloat

    /// 作る（canJoinAllSpaces の窓は、チャットを開いていて普通のアプリのときに作っても、
    /// ほかのアプリのフル画面のスペースに出られることを確かめてある。入力中のチャットからフォーカスを奪わないよう、
    /// ActiveSpace.make のようにアプリの種類を切り替えることはしない）
    static func make(for screen: NSScreen) -> OverlayWindow { OverlayWindow(screen: screen) }

    init(screen: NSScreen) {
        scale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // 普通のウィンドウより上、おもち（.floating）より下
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        // アプリを隠しても（チャットで ⌘H・ほかのアプリで「ほかを隠す」）、おもちと糸は残す
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        // レイヤーをこちらで持つ（layer-hosting：layer を先に入れてから wantsLayer）。
        // AppKit が描き直しのたびにレイヤーの中身や大きさに手を出さないように
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.layer = root
        v.wantsLayer = true
        root.frame = v.bounds
        root.actions = ["bounds": NSNull(), "position": NSNull()]
        contentView = v
        for l in [stickRoot, stringRoot] {
            l.frame = root.bounds
            l.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
            root.addSublayer(l)
        }
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 3
        ringLayer.lineDashPattern = [5, 4]
        ringLayer.contentsScale = scale
        ringLayer.isHidden = true
        previewLayer.isHidden = true
        tearLayer.isHidden = true
        for l in [previewLayer, tearLayer] as [CALayer] { l.contentsScale = scale; root.addSublayer(l) }
        root.addSublayer(ringLayer)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// ディスプレイの枠が変わった（並べ替え・解像度）：窓とレイヤーの大きさを合わせる（描いたものは呼んだ側が描き直す）
    func fit(to f: CGRect) {
        setFrame(f, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView?.frame = NSRect(origin: .zero, size: f.size)
        root.frame = CGRect(origin: .zero, size: f.size)
        for l in [stickRoot, stringRoot] { l.frame = root.bounds }
        CATransaction.commit()
    }

    var stringCount: Int { lines.count }

    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }

    func intersects(_ pts: [CGPoint]) -> Bool {
        guard let f = pts.first else { return false }
        var r = CGRect(origin: f, size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return frame.intersects(r.insetBy(dx: -4, dy: -4))
    }

    func setStrings(_ segs: [(JellyLink, LinkOverlay.StringShape)], styler: (JellyLink, StringLayer) -> Void) {
        let keep = Set(segs.map(\.0))
        for (l, layer) in lines where !keep.contains(l) { layer.removeFromSuperlayer(); lines[l] = nil }
        for (l, s) in segs {
            let layer = lines[l] ?? StringLayer()
            if lines[l] == nil { lines[l] = layer; layer.contentsScale = scale; stringRoot.addSublayer(layer) }
            styler(l, layer)
            layer.setShape(s)
        }
    }

    func reshape(_ l: JellyLink, _ s: LinkOverlay.StringShape) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lines[l]?.setShape(s)
        CATransaction.commit()
    }

    func restyle(_ styler: (JellyLink, StringLayer) -> Void) {
        for (l, layer) in lines { styler(l, layer) }
    }

    /// 串だんごの串：おもちの中心を通る木の串（先は少し出て、最後に持ち手）
    func setSticks(_ items: [LinkOverlay.Stick], bodyWidth w: CGFloat) {
        let keep = Set(items.map(\.id))
        for (id, l) in sticks where !keep.contains(id) { l.removeFromSuperlayer(); sticks[id] = nil }
        for it in items where it.points.count >= 2 {
            let layer = sticks[it.id] ?? {
                let s = CAShapeLayer()
                s.fillColor = nil
                s.lineCap = .round
                s.lineJoin = .round
                s.strokeColor = NSColor(srgbRed: 0.80, green: 0.62, blue: 0.38, alpha: 1).cgColor
                s.shadowColor = NSColor.black.cgColor
                s.shadowOpacity = 0.35
                s.shadowRadius = 1.5
                s.shadowOffset = CGSize(width: 0, height: -1)
                s.contentsScale = scale
                stickRoot.addSublayer(s)
                sticks[it.id] = s
                return s
            }()
            layer.lineWidth = max(3.5, w * 0.05)
            let p = CGMutablePath()
            let a = it.points[0], b = it.points[1]
            let n = it.points.count
            let z = it.points[n - 1], y = it.points[n - 2]
            // 先端（最初のおもちの少し先）と、持ち手（最後のおもちの先）
            func ext(_ from: CGPoint, _ to: CGPoint, _ k: CGFloat) -> CGPoint {
                let d = max(0.001, hypot(to.x - from.x, to.y - from.y))
                return CGPoint(x: to.x + (to.x - from.x) / d * w * k, y: to.y + (to.y - from.y) / d * w * k)
            }
            p.move(to: ext(b, a, 0.55))
            for q in it.points { p.addLine(to: q) }
            p.addLine(to: ext(y, z, 0.95))
            layer.path = p
        }
    }

    func animateDraw(_ l: JellyLink) {
        guard let layer = lines[l] else { return }
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 0.2
        a.toValue = 1
        a.duration = 0.3
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 0
        f.toValue = 1
        f.duration = 0.25
        // 糸は全体が窓の大きさのレイヤーなので、のびる代わりにふわっと出す
        layer.add(f, forKey: "draw")
    }

    /// ドラッグ中の「離すと〜」：つながる＝相手まで細い糸と輪、くっつく＝相手を囲む白い輪、上に載る＝相手の頭の上の輪
    func setPreview(_ pv: LinkOverlay.Preview?, bodyWidth w: CGFloat) {
        guard let pv else {
            if !previewLayer.isHidden || !ringLayer.isHidden {
                previewLayer.isHidden = true
                ringLayer.isHidden = true
                ringLayer.removeAllAnimations()
            }
            return
        }
        let color = pv.ok ? pv.color : LinkOverlay.warnColor
        var center = pv.to
        var r = pv.radius
        switch pv.kind {
        case .link:
            var s = LinkOverlay.shape(pv.from, pv.to, taut: false, body: w)
            s.end *= 0.6
            previewLayer.setShape(s)
            previewLayer.setColors(body: color.withAlphaComponent(0.75), shine: NSColor(white: 1, alpha: 0.5))
            previewLayer.isHidden = false
        case .merge:
            previewLayer.isHidden = true
            r = pv.radius * 0.95
        case .stack:
            previewLayer.isHidden = true
            center = CGPoint(x: pv.to.x, y: pv.to.y + w * 0.36)
            r = pv.radius * 0.62
        }
        let d = r * 2
        if ringLayer.bounds.width != d {
            ringLayer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            ringLayer.path = CGPath(ellipseIn: ringLayer.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        }
        ringLayer.position = center
        ringLayer.strokeColor = (pv.kind == .merge && pv.ok ? LinkOverlay.mochiColor : color).cgColor
        ringLayer.lineDashPattern = pv.kind == .merge ? nil : [5, 4]
        ringLayer.lineWidth = pv.kind == .merge ? 4 : 3
        ringLayer.isHidden = false
        if ringLayer.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 0.94
            a.toValue = 1.06
            a.duration = 0.45
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ringLayer.add(a, forKey: "pulse")
        }
    }

    /// ちぎっている途中の糸：のびるほどまん中が細くくびれ、ちぎれる手前でとても細くなる
    func setTear(_ t: LinkOverlay.Tear?, bodyWidth w: CGFloat) {
        guard let t else { tearLayer.isHidden = true; return }
        let len = hypot(t.to.x - t.from.x, t.to.y - t.from.y)
        let reach = w * JellyManager.tearDistance
        let k = min(1, len / reach)
        let s = LinkOverlay.StringShape(a: t.from, b: t.to, sag: min(len * 0.06, w * 0.15), end: w * (0.42 - 0.22 * k),
                                        neck: max(0.06, 0.75 - 0.69 * k))
        tearLayer.setShape(s)
        let body = t.color.blended(withFraction: 0.55, of: LinkOverlay.mochiColor) ?? t.color
        tearLayer.setColors(body: t.ready ? body.withAlphaComponent(0.95) : body.withAlphaComponent(0.9), shine: NSColor(white: 1, alpha: 0.5))
        tearLayer.isHidden = false
    }

    func setPills(_ items: [LinkOverlay.Pill]) {
        let keep = Set(items.map(\.id))
        for (id, l) in pills where !keep.contains(id) { l.removeFromSuperlayer(); pills[id] = nil }
        for it in items where frame.contains(CGPoint(x: it.at.x + frame.minX, y: it.at.y + frame.minY)) {
            let pill = pills[it.id] ?? makeLabel()
            if pills[it.id] == nil { pills[it.id] = pill; root.addSublayer(pill) }
            configure(pill, text: it.text, at: it.at, color: it.color, size: 11.5, height: 20)
        }
    }

    func setLabels(_ items: [LinkOverlay.Label]) {
        let keep = Set(items.map(\.id))
        for (id, l) in labels where !keep.contains(id) { l.removeFromSuperlayer(); labels[id] = nil }
        for it in items where frame.contains(CGPoint(x: it.at.x + frame.minX, y: it.at.y + frame.minY)) {
            let pill = labels[it.id] ?? makeLabel()
            if labels[it.id] == nil { labels[it.id] = pill; root.addSublayer(pill) }
            configure(pill, text: it.text, at: it.at, color: it.color, size: 10.5, height: 16)
        }
    }

    private func configure(_ pill: CALayer, text: String, at: CGPoint, color: NSColor, size: CGFloat, height h: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let ts = str.size()
        let pad = round(h * 0.38)
        let w = ceil(ts.width) + pad * 2
        pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        // 画面の端で切れないよう、窓（ディスプレイ）の内側に収める
        let x = min(max(at.x, w / 2 + 4), max(w / 2 + 4, frame.width - w / 2 - 4))
        let y = min(max(at.y - h / 2, h / 2 + 2), max(h / 2 + 2, frame.height - h / 2 - 2))
        pill.position = CGPoint(x: round(x), y: round(y))
        pill.backgroundColor = color.blended(withFraction: 0.35, of: .black)?.withAlphaComponent(0.9).cgColor
        if let t = pill.sublayers?.first as? CATextLayer {
            t.string = str
            t.frame = CGRect(x: pad, y: (h - ceil(ts.height)) / 2, width: ceil(ts.width) + 1, height: ceil(ts.height))
        }
    }

    private func makeLabel() -> CALayer {
        let pill = CALayer()
        pill.cornerRadius = 3
        pill.contentsScale = scale
        let t = CATextLayer()
        t.contentsScale = scale
        t.alignmentMode = .left
        pill.addSublayer(t)
        return pill
    }

    /// 糸の中を流れるお餅の塊（まるい・白いふち）
    func addLump(along path: CGPath, color: NSColor, size s: CGFloat, duration: Double, delay: Double) {
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -s / 2, y: -s / 2, width: s, height: s), transform: nil)
        dot.fillColor = color.cgColor
        dot.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
        dot.lineWidth = 1.2
        dot.shadowColor = color.cgColor
        dot.shadowOpacity = 0.8
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.contentsScale = scale
        dot.opacity = 0
        root.addSublayer(dot)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .paced
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.85, 1]
        // 糸の中を押し進むように、少し縦横に伸び縮み
        let squish = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squish.values = [0.8, 1.15, 0.85, 1.1, 0.9]
        let g = CAAnimationGroup()
        g.animations = [move, fade, squish]
        g.duration = duration
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .backwards
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
        dot.add(g, forKey: "move")
        CATransaction.commit()
    }

    /// 餅まきのお餅（白いお餅が回りながら飛ぶ。縁はまく相手の色）
    func addPiece(along path: CGPath, color: NSColor, size s: CGFloat, duration: Double, delay: Double) {
        let piece = CAShapeLayer()
        piece.path = CGPath(roundedRect: CGRect(x: -s / 2, y: -s * 0.36, width: s, height: s * 0.72),
                            cornerWidth: s * 0.36, cornerHeight: s * 0.3, transform: nil)
        piece.fillColor = LinkOverlay.mochiColor.cgColor
        piece.strokeColor = color.cgColor
        piece.lineWidth = 1.6
        piece.shadowColor = NSColor.black.cgColor
        piece.shadowOpacity = 0.3
        piece.shadowRadius = 2
        piece.shadowOffset = CGSize(width: 0, height: -1)
        piece.contentsScale = scale
        piece.opacity = 0
        root.addSublayer(piece)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .paced
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2 * (Bool.random() ? 1 : -1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.9, 1]
        let g = CAAnimationGroup()
        g.animations = [move, spin, fade]
        g.duration = duration
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .backwards
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { piece.removeFromSuperlayer() }
        piece.add(g, forKey: "throw")
        CATransaction.commit()
    }

    func addSnap(_ a: CGPoint, _ b: CGPoint, color: NSColor, width: CGFloat) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        for end in [a, b] {
            let s = CAShapeLayer()
            s.fillColor = nil
            s.lineCap = .round
            s.lineWidth = width
            s.strokeColor = color.cgColor
            s.contentsScale = scale
            let p = CGMutablePath()
            p.move(to: end)
            p.addLine(to: mid)
            s.path = p
            s.strokeEnd = 0
            root.addSublayer(s)
            let shrink = CABasicAnimation(keyPath: "strokeEnd")
            shrink.fromValue = 1
            shrink.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [shrink, fade]
            g.duration = 0.32
            g.timingFunction = CAMediaTimingFunction(name: .easeIn)
            CATransaction.begin()
            CATransaction.setCompletionBlock { s.removeFromSuperlayer() }
            s.add(g, forKey: "snap")
            CATransaction.commit()
        }
    }
}

/// 線の上に出る小さな ✂︎ ボタン（クリックできる小窓。フォーカスは奪わない）
private final class ScissorsPanel: NSPanel {
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 26, height: 26), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let v = ScissorsView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        v.onClick = { [weak self] in self?.onClick?() }
        contentView = v
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(at p: CGPoint) {
        setFrameOrigin(NSPoint(x: round(p.x - 13), y: round(p.y - 13)))
        if !isVisible { orderFrontRegardless() }
    }
}

private final class ScissorsView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.18, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor(white: 1, alpha: 0.85).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 1
        ring.stroke()
        let s = NSAttributedString(string: "✂︎", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold),
                                                               .foregroundColor: NSColor.white])
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }
}
