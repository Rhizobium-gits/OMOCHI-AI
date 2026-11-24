import AppKit
import QuartzCore

/// マウスを受けない描画専用ビュー（イベントは親の JellyHostView が受ける）
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// ドット絵のクラゲ「もち」（MochiSprite）。
///
/// お餅なので宙には浮かず、床に座ったまま（足元の影は絵に入っている）。
/// 動きはドット絵のコマ（ふくらむ・しぼむ・小さく跳ねる・まばたき）だけで、最大 8fps で描き替える。
/// エラーの横ゆれ・長押しの縮み・着地のはずみは Core Animation。
/// 完了・キャンセルでは少しして止まり、タイマーもアニメーションも無くす
final class PixelAvatar: Avatar {
    static func cell(scale: Double) -> Double { (6.0 * scale).rounded() }
    static let topMarginCells: CGFloat = 2.0
    static let bottomMarginCells: CGFloat = 0.5

    static func windowSize(scale: Double) -> CGSize {
        let P = CGFloat(cell(scale: scale))
        return CGSize(width: CGFloat(MochiSprite.cols) * P,
                      height: (CGFloat(MochiSprite.rows) + topMarginCells + bottomMarginCells) * P)
    }

    let view: NSView
    let size: CGSize
    private let P: CGFloat
    private let colors: SpriteColors
    private let cacheKey: String

    private let root = CALayer()
    private let floatLayer = CALayer()
    private let hopLayer = CALayer()
    private let spriteLayer = CALayer()

    private(set) var state: AgentState
    private var timer: Timer?
    private var stateStart = CACurrentMediaTime()
    private var active = false
    private var settling = false
    private var settled = false

    // 表情・手足の状態
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

    init(record: JellyRecord, scale: Double) {
        P = CGFloat(PixelAvatar.cell(scale: scale))
        size = PixelAvatar.windowSize(scale: scale)
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
        hopLayer.frame = root.bounds
        // 拡大・縮小はスプライトの足元を基準に
        let footY = PixelAvatar.bottomMarginCells * P + P * 1.0
        hopLayer.anchorPoint = CGPoint(x: 0.5, y: footY / size.height)
        hopLayer.position = CGPoint(x: size.width / 2, y: footY)

        spriteLayer.frame = CGRect(x: 0, y: PixelAvatar.bottomMarginCells * P,
                                   width: CGFloat(MochiSprite.cols) * P, height: CGFloat(MochiSprite.rows) * P)
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        spriteLayer.actions = ["contents": NSNull(), "opacity": NSNull()]

        root.addSublayer(floatLayer)
        floatLayer.addSublayer(hopLayer)
        hopLayer.addSublayer(spriteLayer)
        [root, floatLayer, hopLayer].forEach { $0.actions = ["transform": NSNull(), "opacity": NSNull(), "position": NSNull()] }

        pose = basePose(for: state, now: CACurrentMediaTime())
        render(force: true)
    }

    var isAnimating: Bool { timer != nil || !(floatLayer.animationKeys() ?? []).isEmpty || !(hopLayer.animationKeys() ?? []).isEmpty }

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

    private func basePose(for s: AgentState, now: Double) -> JellyPose {
        var p = JellyPose()
        switch s {
        case .idle, .thinking, .working: break
        case .completed: p.eyes = .happy; p.mark = .check; p.puff = 2
        case .error: p.eyes = .cross; p.tone = .error; p.mark = .exclaim; p.puff = -1
        case .cancelled: p.eyes = .closed; p.tone = .cancelled; p.puff = -1
        }
        return p
    }

    /// 状態ごとの動きを設定する（宙には浮かない。エラーだけ横にゆれる）
    private func applyStateMotion(transition: Bool) {
        hopLayer.removeAnimation(forKey: "shake")
        hopLayer.removeAnimation(forKey: "hopLoop")
        floatLayer.removeAllAnimations()
        spriteLayer.opacity = state == .cancelled ? 0.85 : 1.0
        switch state {
        case .error: addShakeLoop()
        case .completed, .cancelled: settleSoon()
        default: break
        }
        startTimer()
    }

    private func currentY(_ layer: CALayer) -> CGFloat {
        (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
    }

    /// 完了・キャンセル：ふくらみが落ち着いたら止める（タイマーは tick が止める）
    private func settleSoon() {
        settling = true
        let start = stateStart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.settling, self.state.isTerminal, self.stateStart == start else { return }
            self.settling = false
            self.settled = true
            if self.active { self.tick() }
        }
    }

    /// 状態が始まってからの位置（0〜1。クラゲごとに少しずらす）
    private func phase(_ now: Double, _ period: Double) -> Double {
        ((now - stateStart + seed) / period).truncatingRemainder(dividingBy: 1)
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

    // MARK: - コマ送り（まばたき・手足）

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
            // ゆっくり呼吸：ふつう → ぷく 1 → ふつう（4 秒）。4 回に 1 回は大きく吸う
            let ph = phase(now, 4)
            p.puff = [0, 0, 0, 1, 1, 1, 0, 0][min(7, Int(ph * 8))]
            if Int((now - stateStart + seed) / 4) % 4 == 3 && ph > 0.35 && ph < 0.6 { p.puff = 2 }
        case .thinking:
            // 目がきょろきょろ、頭上に「…」が増えていく。体は「ぷくー」とふくらんで「しゅん」としぼむ（2.6 秒）
            let gl = [(-1, -1), (-1, -1), (1, -1), (1, -1), (0, -1), (0, 0)]
            let gi = Int(el / 0.45) % gl.count
            p.eyes = .open(dx: gl[gi].0, dy: gl[gi].1)
            p.mark = .dots(Int(el / 0.38) % 4)
            let ph = phase(now, 2.6)
            p.puff = ph < 0.7 ? Int(ph / 0.7 * 4) : (ph < 0.82 ? -1 : 0)
        case .working:
            // 「ぽよん」：ふくらむ → 跳ねる → 着地でつぶれる（1/8 秒ごと、8 コマで 1 回）
            let f = Int(el * 8)
            p.puff = [1, 2, 2, 1, 1, 0, 0, 1][f % 8]
            if f % 8 == 2 || f % 8 == 3 { p.lift = 1 }
            if f % 8 == 5 { p.legs = .crouch }
            p.eyes = .open(dx: 0, dy: f % 16 < 8 ? 1 : 0)
        case .error:
            p.mark = Int(el / 0.4) % 3 == 2 ? .none : .exclaim
        case .completed:
            // できた瞬間だけいちばんふくらむ
            p.puff = el < 0.35 ? 3 : 2
        case .cancelled:
            break
        }

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

        // 操作への反応
        // つつく：ぷくっとふくらんで、ちょっと跳ねる（影は床に残る）
        if now < pokeEnd {
            let k = pokeEnd - now
            p.puff = 3
            p.lift = k > 0.12 && k < 0.32 ? 1 : 0
            if case .open = p.eyes { p.eyes = .open(dx: 0, dy: -1) }
        }
        // つまむと「のび〜」、着地・長押しでぎゅっとつぶれる
        if dragging { p.legs = .dangle; p.eyes = state.isTerminal ? p.eyes : .open(dx: 0, dy: 1); p.lift = 0 }
        if now < landEnd { p.legs = .crouch }
        if pressing { p.eyes = .closed; p.legs = .crouch; p.mark = .none }

        pose = p
        render(force: false)

        // 終了状態は揺れが収まり、反応も終わったらタイマーを止める
        if state.isTerminal && settled && now > pokeEnd && now > landEnd && !dragging { stopTimer() }
    }

    private func render(force: Bool) {
        if !force, shownPose == pose { return }
        shownPose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = MochiSprite.image(pose, colors: colors, key: cacheKey)
        CATransaction.commit()
    }

    // MARK: - 操作

    /// 体の中心：お餅は低いので、キャンバスの下から 4 行目あたり
    var anchor: CGPoint { CGPoint(x: size.width / 2, y: (PixelAvatar.bottomMarginCells + 4) * P) }
    /// 足のすぐ下
    var labelY: CGFloat { PixelAvatar.bottomMarginCells * P + 0.6 * P }

    func hitTest(_ p: CGPoint) -> Bool {
        let dy = currentY(floatLayer) + currentY(hopLayer)
        let base = PixelAvatar.bottomMarginCells * P
        let rows = CGFloat(MochiSprite.rows)
        // スプライト本体（キャンバスの列 2..12、行 3..10）を少し広めに
        let rect = CGRect(x: 1.5 * P, y: base + (rows - 11) * P - 0.5 * P + dy,
                          width: 12 * P, height: 9 * P)
        return rect.contains(p)
    }

    func pointerMoved(inside: Bool, local: CGPoint) {
        guard inside, !state.isTerminal, state != .error else {
            if hoverLook != nil { hoverLook = nil; if active { tick() } }
            return
        }
        // 目でカーソルを追う
        let cx = size.width / 2
        let cy = PixelAvatar.bottomMarginCells * P + 4 * P
        let dx = local.x < cx - P * 1.5 ? -1 : (local.x > cx + P * 1.5 ? 1 : 0)
        let dy = local.y > cy + P ? -1 : (local.y < cy - P * 1.5 ? 1 : 0)
        if hoverLook?.dx != dx || hoverLook?.dy != dy {
            hoverLook = (dx, dy)
            if active { startTimer(); tick() }
        }
    }

    func poke() {
        // ぷくっとふくらんで跳ね、着地で少しつぶれる（コマで描く）
        pokeEnd = CACurrentMediaTime() + 0.45
        landEnd = pokeEnd + 0.12
        startTimer()
        tick()
    }

    func dragBegan() {
        dragging = true
        startTimer()
        tick()
    }

    func dragEnded() {
        dragging = false
        landEnd = CACurrentMediaTime() + 0.15
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
        bounce.values = [1, 0.86, 1.06, 1]
        bounce.keyTimes = [0, 0.3, 0.65, 1]
        bounce.duration = 0.35
        hopLayer.add(bounce, forKey: "land")
        startTimer()
        tick()
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
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        hopLayer.add(fade, forKey: "spawnFade")
        pokeEnd = CACurrentMediaTime() + 0.5
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
            floatLayer.removeAllAnimations()
            hopLayer.removeAllAnimations()
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
        floatLayer.removeAllAnimations()
        hopLayer.removeAllAnimations()
    }
}
