import AppKit
import QuartzCore

/// マウスを受けない描画専用ビュー（イベントは親の JellyHostView が受ける）
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// おもち：ドット絵のお餅「まるもち」（MochiSprite）か、Blender で描いたリアルなお餅（RealMochiArt）。
/// どちらも同じ 15×12 マスのキャンバスに描くので、置き場所・動き・当たり判定は共通。
///
/// お餅なので宙には浮かず、床に座ったまま（足元の影は床に残る）。
/// 負荷を抑えつつ滑らかに動かす設計：
/// - 呼吸・ふくらむ・しぼむ・跳ねるといった連続的な動きは Core Animation の伸び縮み（足元を基準）と上下の移動に任せる
///   （WindowServer 側で画面の速さで補間されるので、アプリのメインスレッドは毎フレーム起きない）
/// - アプリが描き替えるのはコマ（まばたき・目線・頭上の記号・状態ごとの形）だけで、最大 8fps
/// - 形が変わる瞬間（完了でふくらむ・エラーでしぼむ）は、伸び縮みを 1 回はさんで段差を目立たせない
/// - 完了・キャンセルでは少しして止まり、タイマーもアニメーションも無くす
///
/// レイヤー：root ─ shadowLayer（床の影） / floatLayer（跳ねる：上下）─ breathLayer（呼吸：伸び縮み）
///                 ─ hopLayer（つつく・長押し・着地・出現・横ゆれ）─ spriteLayer（絵）
final class MochiAvatar: Avatar {
    /// 絵の種類：ドット絵か、リアルなお餅か
    enum Art { case pixel, real }

    static func cell(scale: Double) -> Double { (6.0 * scale).rounded() }
    static let topMarginCells: CGFloat = 2.0
    static let bottomMarginCells: CGFloat = 0.5
    /// 左右の余白（会話が大きくなってふくらんでも、窓の端で切れないように）
    static let sideMarginCells: CGFloat = 1.0

    static func windowSize(scale: Double) -> CGSize {
        let P = CGFloat(cell(scale: scale))
        return CGSize(width: (CGFloat(MochiSprite.cols) + 2 * sideMarginCells) * P,
                      height: (CGFloat(MochiSprite.rows) + topMarginCells + bottomMarginCells) * P)
    }

    let view: NSView
    let size: CGSize
    private let P: CGFloat
    let art: Art
    /// リアルな絵を描くときの 1 マスのピクセル数（画面の倍率込み）
    private let px: CGFloat
    private let colors: SpriteColors
    private let cacheKey: String

    private let root = CALayer()
    private let shadowLayer = CALayer()
    private let floatLayer = CALayer()
    /// 会話の大きさでふくらむ（足元を基準にゆっくり大きく）
    private let growLayer = CALayer()
    private let breathLayer = CALayer()
    private let hopLayer = CALayer()
    private let spriteLayer = CALayer()
    /// 頭上の「…」「!」「✓」（体の伸び縮みでゆがまないよう別のレイヤー）
    private let markLayer = CALayer()

    private(set) var state: AgentState
    private var timer: Timer?
    private var stateStart = CACurrentMediaTime()
    private var active = false
    private var settling = false
    private var settled = false

    // 表情・形の状態
    private var pose = JellyPose()
    private var shownPose: JellyPose?
    private var nextBlink = CACurrentMediaTime() + 2.5
    private var blinkEnd = 0.0
    private var glance: (dx: Int, dy: Int, until: Double)?
    private var nextGlance = CACurrentMediaTime() + 6
    private var hoverLook: (dx: Int, dy: Int)?
    private var pokeEnd = 0.0
    private var dragging = false
    private var pressing = false
    private var landEnd = 0.0
    private let seed: Double
    /// 会話の大きさ・硬さ・あんこ・鏡餅・温め直し
    private(set) var look = MochiLook()

    init(record: JellyRecord, scale: Double, art: Art = .pixel) {
        P = CGFloat(MochiAvatar.cell(scale: scale))
        // 絵がそろっていなければドット絵にする
        self.art = art == .real && RealMochiArt.available ? .real : .pixel
        px = P * (NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        size = MochiAvatar.windowSize(scale: scale)
        colors = SpriteColors.from(record.color)
        cacheKey = record.color.key
        state = record.state
        seed = Double(record.number) * 0.618

        let v = PassthroughView(frame: NSRect(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer = root
        view = v

        root.frame = CGRect(origin: .zero, size: size)
        floatLayer.frame = root.bounds
        // 伸び縮み・拡大縮小は足元（床の線）を基準に
        let footY = MochiAvatar.bottomMarginCells * P + P * 1.0
        for l in [growLayer, breathLayer, hopLayer] {
            l.bounds = root.bounds
            l.anchorPoint = CGPoint(x: 0.5, y: footY / size.height)
            l.position = CGPoint(x: size.width / 2, y: footY)
        }

        spriteLayer.frame = CGRect(x: MochiAvatar.sideMarginCells * P, y: MochiAvatar.bottomMarginCells * P,
                                   width: CGFloat(MochiSprite.cols) * P, height: CGFloat(MochiSprite.rows) * P)
        // ドット絵は補間しない。リアルな絵はなめらかに
        let filter: CALayerContentsFilter = self.art == .real ? .linear : .nearest
        spriteLayer.magnificationFilter = filter
        spriteLayer.minificationFilter = filter
        spriteLayer.contentsGravity = .resize
        spriteLayer.actions = ["contents": NSNull(), "opacity": NSNull()]
        markLayer.frame = spriteLayer.frame
        markLayer.magnificationFilter = filter
        markLayer.minificationFilter = filter
        markLayer.contentsGravity = .resize
        markLayer.actions = ["contents": NSNull(), "opacity": NSNull()]

        // 床の影（体が跳ねても床に残り、高く上がると小さくなる）。リアルな絵はぼかした楕円
        if self.art == .real {
            shadowLayer.contents = RealMochiArt.shadowImage
            shadowLayer.contentsGravity = .resize
        } else {
            shadowLayer.backgroundColor = CGColor(gray: 0, alpha: SpriteColors.shadowAlpha)
        }
        shadowLayer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "opacity": NSNull()]

        root.addSublayer(shadowLayer)
        root.addSublayer(floatLayer)
        root.addSublayer(markLayer)
        floatLayer.addSublayer(growLayer)
        growLayer.addSublayer(breathLayer)
        breathLayer.addSublayer(hopLayer)
        hopLayer.addSublayer(spriteLayer)
        [root, floatLayer, growLayer, breathLayer, hopLayer].forEach { $0.actions = ["transform": NSNull(), "opacity": NSNull(), "position": NSNull()] }

        pose = basePose(for: state, now: CACurrentMediaTime())
        render(force: true)
    }

    var isAnimating: Bool {
        timer != nil || [floatLayer, breathLayer, hopLayer, shadowLayer].contains { !($0.animationKeys() ?? []).isEmpty }
    }

    // MARK: - 状態

    func setState(_ s: AgentState) {
        let changed = s != state
        state = s
        stateStart = CACurrentMediaTime()
        settled = false
        settling = false
        if active { applyStateMotion(transition: changed) }
        pose = basePose(for: s, now: stateStart)
        render(force: true)
    }

    /// 状態ごとの形と表情（形が変わるのは完了・エラー・キャンセルだけ。呼吸や跳ねは Core Animation）
    private func basePose(for s: AgentState, now: Double) -> JellyPose {
        var p = JellyPose()
        p.char = look.char
        p.hard = look.hard
        p.anko = look.anko
        p.crown = look.crown
        switch s {
        case .idle, .thinking, .working: break
        case .completed: p.eyes = .happy; p.mark = .check; p.puff = 2
        case .error: p.eyes = .cross; p.tone = .error; p.mark = .exclaim; p.puff = -1
        case .cancelled: p.eyes = .closed; p.tone = .cancelled; p.puff = -1
        }
        return p
    }

    /// 状態ごとの動きを設定する（宙には浮かない。いまの伸び縮みから滑らかにつなぐ）
    private func applyStateMotion(transition: Bool) {
        hopLayer.removeAnimation(forKey: "shake")
        spriteLayer.opacity = state == .cancelled ? 0.85 : 1.0
        // 周期はおもちごとに少し変えて、並んでいても息がそろわないように
        let jitter = (seed * 0.37).truncatingRemainder(dividingBy: 1) * 0.5
        switch state {
        case .idle:
            // ゆっくり呼吸。4 回に 1 回は大きく吸う。硬くなるほど息が浅い（硬いお餅はふくらまない）
            let amp: CGFloat = look.hard >= 2 ? 0.2 : (look.hard == 1 ? 0.55 : 1)
            func a(_ v: [CGFloat]) -> [CGFloat] { v.map { 1 + ($0 - 1) * amp } }
            setBreath(loop(period: (4.0 + jitter) * 4 * (look.hard > 0 ? 1.4 : 1),
                           y: a([1, 1.045, 1, 1.045, 1, 1.045, 1, 1.09, 1]),
                           x: a([1, 0.985, 1, 0.985, 1, 0.985, 1, 0.975, 1]),
                           times: [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1],
                           timing: Array(repeating: .easeInEaseOut, count: 8)))
            setHop(nil)
        case .thinking:
            // 「ぷくー」と少しずつふくらんで、「しゅん」としぼみ、少し弾んで戻る
            setBreath(loop(period: 2.6 + jitter * 0.4,
                           y: [1, 1.2, 0.88, 1.03, 1],
                           x: [1, 1.06, 1.1, 0.99, 1],
                           times: [0, 0.68, 0.78, 0.9, 1],
                           timing: [.easeInEaseOut, .easeIn, .easeOut, .easeInEaseOut]))
            setHop(nil)
        case .working:
            // 「ぽよん」：かがんで → 伸びて跳ね → 空中でまるく → 着地でつぶれる
            let period = 0.95 + jitter * 0.1
            let times: [NSNumber] = [0, 0.12, 0.3, 0.55, 0.7, 0.8, 1]
            setBreath(loop(period: period,
                           y: [0.92, 1.1, 1.02, 1.0, 1.05, 0.86, 0.92],
                           x: [1.05, 0.95, 0.99, 1.0, 0.97, 1.09, 1.05],
                           times: times,
                           timing: [.easeOut, .easeOut, .easeInEaseOut, .easeIn, .easeOut, .easeInEaseOut]))
            setHop(hopLoop(period: period, height: P * 0.7))
        case .completed:
            // できた！で一度ぷくっと弾んで、ふくらんだまま止まる
            setBreath(once(duration: 0.8, y: [0.9, 1.16, 0.95, 1.03, 1], x: [1.06, 1.05, 1.03, 0.99, 1], times: [0, 0.3, 0.55, 0.8, 1]))
            setHop(nil)
            settleSoon()
        case .error:
            // しゅんとしぼむ（そのあとは横ゆれだけ）
            setBreath(once(duration: 0.5, y: [1.12, 0.9, 1.02, 1], x: [0.96, 1.06, 0.99, 1], times: [0, 0.45, 0.75, 1]))
            setHop(nil)
            addShakeLoop()
        case .cancelled:
            setBreath(once(duration: 0.6, y: [1.1, 0.92, 1.01, 1], x: [0.97, 1.05, 1.0, 1], times: [0, 0.5, 0.8, 1]))
            setHop(nil)
            settleSoon()
        }
        startTimer()
    }

    // MARK: - 伸び縮み・跳ね（Core Animation）

    private func timings(_ t: [CAMediaTimingFunctionName]) -> [CAMediaTimingFunction] { t.map { CAMediaTimingFunction(name: $0) } }

    /// 足元を基準に縦・横へ伸び縮みするくり返し
    private func loop(period: Double, y: [CGFloat], x: [CGFloat], times: [NSNumber], timing: [CAMediaTimingFunctionName]) -> CAAnimation {
        let ay = CAKeyframeAnimation(keyPath: "transform.scale.y")
        ay.values = y
        let ax = CAKeyframeAnimation(keyPath: "transform.scale.x")
        ax.values = x
        for a in [ay, ax] { a.keyTimes = times; a.timingFunctions = timings(timing) }
        let g = CAAnimationGroup()
        g.animations = [ay, ax]
        g.duration = period
        g.repeatCount = .infinity
        return g
    }

    /// 1 回だけの伸び縮み（最後は 1 に戻る）
    private func once(duration: Double, y: [CGFloat], x: [CGFloat], times: [NSNumber]) -> CAAnimation {
        let ay = CAKeyframeAnimation(keyPath: "transform.scale.y")
        ay.values = y
        let ax = CAKeyframeAnimation(keyPath: "transform.scale.x")
        ax.values = x
        for a in [ay, ax] {
            a.keyTimes = times
            a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: times.count - 1)
        }
        let g = CAAnimationGroup()
        g.animations = [ay, ax]
        g.duration = duration
        return g
    }

    /// 跳ねるくり返し（体は上下、影は高く上がるほど小さく）
    private func hopLoop(period: Double, height: CGFloat) -> (body: CAAnimation, shadow: CAAnimation) {
        let times: [NSNumber] = [0, 0.12, 0.42, 0.72, 1]
        let t = timings([.linear, .easeOut, .easeIn, .linear])
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, 0, height, 0, 0]
        a.keyTimes = times
        a.timingFunctions = t
        a.duration = period
        a.repeatCount = .infinity
        let s = CAKeyframeAnimation(keyPath: "transform.scale.x")
        s.values = [1, 1, 0.72, 1, 1]
        s.keyTimes = times
        s.timingFunctions = t
        s.duration = period
        s.repeatCount = .infinity
        return (a, s)
    }

    /// 呼吸の層を、いまの伸び縮みから次の動きの最初の形へ滑らかにつないでから始める
    private func setBreath(_ next: CAAnimation?) {
        let pres = breathLayer.presentation()
        let sx = (pres?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? 1
        let sy = (pres?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? 1
        breathLayer.removeAllAnimations()
        // 次の動きの最初の値（無ければ 1）
        func first(_ key: String) -> CGFloat {
            let a = (next as? CAAnimationGroup)?.animations?.first { ($0 as? CAKeyframeAnimation)?.keyPath == key } as? CAKeyframeAnimation
            return (a?.values?.first as? CGFloat) ?? 1
        }
        let tx = first("transform.scale.x"), ty = first("transform.scale.y")
        var lead = 0.0
        // 1 回だけの動き（完了・エラーなど）は形が変わる瞬間に始めたいので、つながずにすぐ始める
        if next?.repeatCount ?? .infinity != 0, abs(sx - tx) > 0.004 || abs(sy - ty) > 0.004 {
            lead = 0.22
            let bx = CABasicAnimation(keyPath: "transform.scale.x")
            bx.fromValue = sx
            bx.toValue = tx
            let by = CABasicAnimation(keyPath: "transform.scale.y")
            by.fromValue = sy
            by.toValue = ty
            for b in [bx, by] { b.duration = lead; b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
            let g = CAAnimationGroup()
            g.animations = [bx, by]
            g.duration = lead
            breathLayer.add(g, forKey: "breathIn")
        }
        guard let next else { return }
        next.beginTime = breathLayer.convertTime(CACurrentMediaTime(), from: nil) + lead
        breathLayer.add(next, forKey: "breath")
    }

    /// 跳ねる層（と影）を、いまの高さから次の動きへつなぐ
    private func setHop(_ next: (body: CAAnimation, shadow: CAAnimation)?) {
        let cur = currentY(floatLayer)
        floatLayer.removeAllAnimations()
        shadowLayer.removeAnimation(forKey: "hop")
        var lead = 0.0
        if abs(cur) > 0.3 {
            lead = 0.18
            let b = CABasicAnimation(keyPath: "transform.translation.y")
            b.fromValue = cur
            b.toValue = 0
            b.duration = lead
            b.timingFunction = CAMediaTimingFunction(name: .easeIn)
            floatLayer.add(b, forKey: "hopIn")
        }
        guard let next else { return }
        let start = floatLayer.convertTime(CACurrentMediaTime(), from: nil) + lead
        next.body.beginTime = start
        next.shadow.beginTime = shadowLayer.convertTime(CACurrentMediaTime(), from: nil) + lead
        floatLayer.add(next.body, forKey: "hop")
        shadowLayer.add(next.shadow, forKey: "hop")
    }

    private func currentY(_ layer: CALayer) -> CGFloat {
        (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
    }

    /// 完了・キャンセル：弾みが落ち着いたら止める（タイマーは tick が止める）
    private func settleSoon() {
        settling = true
        let start = stateStart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.settling, self.state.isTerminal, self.stateStart == start else { return }
            self.settling = false
            self.settled = true
            if self.active { self.tick() }
        }
    }

    private func addShakeLoop() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let d = P * 0.35
        shake.values = [0, -d, d, -d, d * 0.6, 0, 0]
        shake.keyTimes = [0, 0.04, 0.08, 0.12, 0.16, 0.2, 1]
        shake.duration = 2.6
        shake.repeatCount = .infinity
        hopLayer.add(shake, forKey: "shake")
    }

    // MARK: - コマ送り（まばたき・目線・頭上の記号）

    private func startTimer() {
        guard active, timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let el = now - stateStart
        var p = basePose(for: state, now: now)

        switch state {
        case .idle:
            if now > nextGlance && glance == nil {
                glance = (dx: Bool.random() ? 1 : -1, dy: Int.random(in: -1...0), until: now + 1.1)
                nextGlance = now + Double.random(in: 5...9)
            }
            if let g = glance { if now < g.until { p.eyes = .open(dx: g.dx, dy: g.dy) } else { glance = nil } }
        case .thinking:
            // 目がきょろきょろ、頭上に「…」が増えていく
            let gl = [(-1, -1), (-1, -1), (1, -1), (1, -1), (0, -1), (0, 0)]
            let gi = Int(el / 0.45) % gl.count
            p.eyes = .open(dx: gl[gi].0, dy: gl[gi].1)
            p.mark = .dots(Int(el / 0.38) % 4)
        case .working:
            // 目線は手もとと前をいったりきたり
            p.eyes = .open(dx: 0, dy: Int(el * 8) % 16 < 8 ? 1 : 0)
        case .error:
            p.mark = Int(el / 0.4) % 3 == 2 ? .none : .exclaim
        case .completed, .cancelled:
            break
        }

        // 温め直し中：頭から湯気
        if look.warming && (state == .thinking || state == .working) { p.mark = .steam(Int(now / 0.3) % 4) }

        // まばたき（終了状態以外）
        if !state.isTerminal && state != .error {
            if now > nextBlink {
                blinkEnd = now + 0.13
                nextBlink = now + Double.random(in: 2.2...5.5)
                if Double.random(in: 0...1) < 0.2 { nextBlink = now + 0.35 }  // たまに二度まばたき
            }
            if now < blinkEnd { p.eyes = .closed }
            if let h = hoverLook, now >= blinkEnd, case .open = p.eyes { p.eyes = .open(dx: h.dx, dy: h.dy) }
        }

        // 操作への反応（ぷくっと弾む・伸びる・つぶれるは Core Animation、ここは目と形だけ）
        if now < pokeEnd, case .open = p.eyes { p.eyes = .open(dx: 0, dy: -1) }
        // つまむと「のび〜」、着地・長押しでぎゅっとつぶれる
        if dragging { p.legs = .dangle; p.eyes = state.isTerminal ? p.eyes : .open(dx: 0, dy: 1) }
        if now < landEnd { p.legs = .crouch }
        if pressing { p.eyes = .closed; p.legs = .crouch; p.mark = .none }

        pose = p
        render(force: false)

        // 終了状態は弾みが収まり、反応も終わったらタイマーを止める
        if state.isTerminal && settled && now > pokeEnd && now > landEnd && !dragging { stopTimer() }
    }

    private func render(force: Bool) {
        if !force, shownPose == pose { return }
        let shapeChanged = shownPose.map { MochiSprite.widths($0) != MochiSprite.widths(pose) || $0.lift != pose.lift } ?? true
        shownPose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if art == .real, let body = RealMochiArt.body(pose, colors: colors, key: cacheKey, px: px) {
            spriteLayer.contents = body
            markLayer.contents = RealMochiArt.marks(pose, colors: colors, key: cacheKey, px: px)
        } else {
            spriteLayer.contents = MochiSprite.image(pose, colors: colors, key: cacheKey, shadow: false, part: .body)
            markLayer.contents = pose.mark == .none ? nil : MochiSprite.image(pose, colors: colors, key: cacheKey, shadow: false, part: .marks)
        }
        if shapeChanged { layoutShadow() }
        CATransaction.commit()
    }

    /// 床の影：いまの形のいちばん下より少し短く、床の行の上半分
    private func layoutShadow() {
        if art == .real {
            // 体の幅より少し狭い、床の線にかかるぼかした楕円（跳ねたコマでは小さく）
            let w = RealMochiArt.bodyWidth(pose) * (pose.lift > 0 ? 0.7 : 0.94) * P
            let frame = CGRect(x: size.width / 2 - w / 2, y: MochiAvatar.bottomMarginCells * P + P * 0.55, width: w, height: P * 0.9)
            shadowLayer.bounds = CGRect(origin: .zero, size: frame.size)
            shadowLayer.position = CGPoint(x: frame.midX, y: frame.midY)
            return
        }
        let sw = CGFloat(MochiSprite.shadowHalfWidth(pose))
        let half = P / 2
        let frame = CGRect(x: (7 - sw + MochiAvatar.sideMarginCells) * P, y: MochiAvatar.bottomMarginCells * P + half, width: (2 * sw + 1) * P, height: half)
        shadowLayer.bounds = CGRect(origin: .zero, size: frame.size)
        shadowLayer.position = CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: - 操作

    /// 体の中心：お餅は低いので、キャンバスの下から 4 行目あたり
    var anchor: CGPoint { CGPoint(x: size.width / 2, y: (MochiAvatar.bottomMarginCells + 4) * P) }
    /// 足のすぐ下
    var labelY: CGFloat { MochiAvatar.bottomMarginCells * P + 0.6 * P }

    func hitTest(_ p: CGPoint) -> Bool {
        let dy = currentY(floatLayer) + currentY(hopLayer)
        let base = MochiAvatar.bottomMarginCells * P
        let rows = CGFloat(MochiSprite.rows)
        // スプライト本体（キャンバスの列 2..12、行 3..10）を少し広めに
        let g = growScale
        let rect = CGRect(x: size.width / 2 - 6 * P * g, y: base + (rows - 11) * P - 0.5 * P + dy,
                          width: 12 * P * g, height: 9 * P * g)
        return rect.contains(p)
    }

    func pointerMoved(inside: Bool, local: CGPoint) {
        guard inside, !state.isTerminal, state != .error else {
            if hoverLook != nil { hoverLook = nil; if active { tick() } }
            return
        }
        // 目でカーソルを追う
        let cx = size.width / 2
        let cy = MochiAvatar.bottomMarginCells * P + 4 * P
        let dx = local.x < cx - P * 1.5 ? -1 : (local.x > cx + P * 1.5 ? 1 : 0)
        let dy = local.y > cy + P ? -1 : (local.y < cy - P * 1.5 ? 1 : 0)
        if hoverLook?.dx != dx || hoverLook?.dy != dy {
            hoverLook = (dx, dy)
            if active { startTimer(); tick() }
        }
    }

    func poke() {
        // ぷくっとふくらみながら跳ね、着地でむにっとつぶれて戻る（影は床で小さくなる）
        let duration = 0.55
        pokeEnd = CACurrentMediaTime() + duration
        let times: [NSNumber] = [0, 0.18, 0.45, 0.72, 0.84, 1]
        let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
        sy.values = [1, 1.16, 1.06, 1.0, 0.86, 1]
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [1, 1.04, 1.02, 0.98, 1.1, 1]
        let ty = CAKeyframeAnimation(keyPath: "transform.translation.y")
        ty.values = [0, P * 0.3, P * 1.2, 0, 0, 0]
        for a in [sy, sx, ty] {
            a.keyTimes = times
            a.timingFunctions = timings([.easeOut, .easeOut, .easeIn, .easeOut, .easeInEaseOut])
        }
        let g = CAAnimationGroup()
        g.animations = [sy, sx, ty]
        g.duration = duration
        hopLayer.add(g, forKey: "poke")
        let sh = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sh.values = [1, 0.9, 0.7, 1, 1.05, 1]
        sh.keyTimes = times
        sh.timingFunctions = timings([.easeOut, .easeOut, .easeIn, .easeOut, .easeInEaseOut])
        sh.duration = duration
        shadowLayer.add(sh, forKey: "poke")
        startTimer()
        tick()
    }

    func dragBegan() {
        dragging = true
        // 形が「のび〜」に変わる段差を、縦の伸びでなめらかに
        let s = CAKeyframeAnimation(keyPath: "transform.scale.y")
        s.values = [0.8, 1.08, 0.97, 1]
        s.keyTimes = [0, 0.4, 0.75, 1]
        s.timingFunctions = timings([.easeOut, .easeInEaseOut, .easeInEaseOut])
        s.duration = 0.35
        hopLayer.add(s, forKey: "pick")
        startTimer()
        tick()
    }

    func dragEnded() {
        dragging = false
        landEnd = CACurrentMediaTime() + 0.15
        let by = CAKeyframeAnimation(keyPath: "transform.scale.y")
        by.values = [1.15, 0.84, 1.06, 0.98, 1]
        let bx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        bx.values = [0.9, 1.1, 0.97, 1.01, 1]
        for a in [by, bx] {
            a.keyTimes = [0, 0.3, 0.6, 0.82, 1]
            a.timingFunctions = timings([.easeOut, .easeInEaseOut, .easeInEaseOut, .easeInEaseOut])
        }
        let g = CAAnimationGroup()
        g.animations = [by, bx]
        g.duration = 0.45
        hopLayer.add(g, forKey: "land")
        startTimer()
        tick()
    }

    // MARK: - 会話の大きさ・硬さ・あんこ・鏡餅・温め直し

    private var growScale: CGFloat { MochiPlay.growScale(look.fullness) }

    func setLook(_ l: MochiLook) {
        guard l != look else { return }
        let old = look
        look = l
        if abs(old.fullness - l.fullness) > 0.001 {
            // ゆっくりふくらむ・しぼむ（いまの大きさから）
            let from = (growLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? MochiPlay.growScale(old.fullness)
            let to = growScale
            growLayer.transform = CATransform3DMakeScale(to, to, 1)
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = from
            a.toValue = to
            a.duration = 0.9
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            growLayer.add(a, forKey: "grow")
        }
        // 硬さが変わったら、息の深さを変える
        if old.hard != l.hard, active, state == .idle { applyStateMotion(transition: false) }
        pose = basePose(for: state, now: CACurrentMediaTime())
        render(force: true)
        if l.warming && !old.warming { startTimer() }
        if active { tick() }
    }

    /// くっつく：相手を取り込んで、横にむにっと広がってからぷくっとまとまる
    func absorb() {
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [1, 1.32, 0.9, 1.06, 1]
        let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
        sy.values = [1, 0.72, 1.22, 0.96, 1]
        for a in [sx, sy] {
            a.keyTimes = [0, 0.28, 0.58, 0.82, 1]
            a.timingFunctions = timings([.easeOut, .easeInEaseOut, .easeInEaseOut, .easeInEaseOut])
        }
        let g = CAAnimationGroup()
        g.animations = [sx, sy]
        g.duration = 0.75
        hopLayer.add(g, forKey: "absorb")
        startTimer()
    }

    /// くっついて溶ける（消えるときに、横に平たく広がりながら薄くなる）
    func melt(_ done: @escaping () -> Void) {
        stopTimer()
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let sx = CABasicAnimation(keyPath: "transform.scale.x")
        sx.toValue = 1.45
        let sy = CABasicAnimation(keyPath: "transform.scale.y")
        sy.toValue = 0.18
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [sx, sy, fade]
        g.duration = 0.3
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        hopLayer.add(g, forKey: "melt")
        for l in [shadowLayer, markLayer] {
            let f = CABasicAnimation(keyPath: "opacity")
            f.toValue = 0
            f.duration = 0.2
            f.fillMode = .forwards
            f.isRemovedOnCompletion = false
            l.add(f, forKey: "melt")
        }
        CATransaction.commit()
    }

    // MARK: - 出現・消滅・表示

    func spawn() {
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.15
        pop.toValue = 1.0
        pop.damping = 11
        pop.stiffness = 240
        pop.mass = 1
        pop.duration = pop.settlingDuration
        hopLayer.add(pop, forKey: "spawn")
        for l in [hopLayer, shadowLayer] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            l.add(fade, forKey: "spawnFade")
        }
        startTimer()
    }

    func despawn(_ done: @escaping () -> Void) {
        stopTimer()
        pressing = false
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.toValue = 0.1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.byValue = P * 2
        let g = CAAnimationGroup()
        g.animations = [shrink, fade, rise]
        g.duration = 0.32
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        hopLayer.add(g, forKey: "despawn")
        let sf = CABasicAnimation(keyPath: "opacity")
        sf.toValue = 0
        sf.duration = 0.2
        sf.fillMode = .forwards
        sf.isRemovedOnCompletion = false
        shadowLayer.add(sf, forKey: "despawn")
        markLayer.add(sf, forKey: "despawn")
        CATransaction.commit()
    }

    func setActive(_ a: Bool) {
        guard a != active else { return }
        active = a
        if a {
            settled = false
            applyStateMotion(transition: false)
            tick()
        } else {
            stopTimer()
            for l in [floatLayer, breathLayer, hopLayer, shadowLayer] { l.removeAllAnimations() }
        }
    }

    func setFrameRates(max: Int, calm: Int) {}

    /// 長押し：少し遅れてから、ぎゅっと縮みながら震えだす（離せば元に戻る）
    func pressBegan(duration: Double) {
        let delay = 0.15
        let now = hopLayer.convertTime(CACurrentMediaTime(), from: nil)
        let squeeze = CABasicAnimation(keyPath: "transform.scale")
        squeeze.fromValue = 1.0
        squeeze.toValue = 0.72
        squeeze.beginTime = now + delay
        squeeze.duration = duration - delay
        squeeze.timingFunction = CAMediaTimingFunction(name: .easeIn)
        squeeze.fillMode = .forwards
        squeeze.isRemovedOnCompletion = false
        hopLayer.add(squeeze, forKey: "press")
        let tremble = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let d = P * 0.22
        tremble.values = [0, -d, d, -d, d, 0]
        tremble.duration = 0.12
        tremble.repeatCount = Float((duration - delay) / 0.12)
        tremble.beginTime = now + delay
        tremble.isAdditive = true
        hopLayer.add(tremble, forKey: "pressShake")
        pressing = true
        startTimer()
    }

    func pressCancelled() {
        pressing = false
        guard hopLayer.animation(forKey: "press") != nil else { return }
        let cur = (hopLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        hopLayer.removeAnimation(forKey: "press")
        hopLayer.removeAnimation(forKey: "pressShake")
        let back = CASpringAnimation(keyPath: "transform.scale")
        back.fromValue = cur
        back.toValue = 1.0
        back.damping = 12
        back.stiffness = 300
        back.duration = back.settlingDuration
        hopLayer.add(back, forKey: "pressBack")
        if active { tick() }
    }

    func teardown() {
        stopTimer()
        root.removeAllAnimations()
        for l in [floatLayer, breathLayer, hopLayer, shadowLayer] { l.removeAllAnimations() }
    }
}
