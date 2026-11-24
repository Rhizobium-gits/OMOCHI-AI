import AppKit
import CoreGraphics
import ImageIO

/// 「リアルなおもち」の絵：Blender で描いた丸餅（Resources/mochi/mochi-<形>.png）に、おもちの色・目・頭上の記号を重ねる。
///
/// 絵はドット絵のまるもち（MochiSprite）と同じ 15×12 マスのキャンバスに、同じ床（10 行目の下の線）で描いてあるので、
/// 置き場所・当たり判定・つながりの線・伸び縮みと跳ね（Core Animation）は MochiAvatar がドット絵と同じに扱う。
/// 絵は scripts/banner/mochi_assets.py（Blender）→ scripts/banner/sprites.py で作る
enum RealMochiArt {
    /// 元の絵の 1 マス（px）
    static let sourceCell: CGFloat = 32
    /// 体の形ごとの絵（MochiSprite のふくらみの段階に合わせる）
    enum Level: String, CaseIterable { case flat, rest, puff1, puff2, puff3 }

    // MARK: - 元の絵

    /// 絵のキャッシュ（アプリではメインスレッドからだけ使うが、テストは並列に呼ぶので鍵をかける。中で呼び合うので再入できる鍵）
    private static let lock = NSRecursiveLock()
    private static var bases: [Level: CGImage] = [:]
    private static var boxes: [Level: CGRect] = [:]
    private static var missing = false

    /// 絵の場所：アプリの中（Contents/Resources/mochi）。swift run のときはソースの Resources/mochi
    static func url(_ level: Level) -> URL? {
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("mochi/mochi-\(level.rawValue).png")]
        #if DEBUG
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/mochi/mochi-\(level.rawValue).png"))
        #endif
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 絵がそろっているか（無ければ見た目はドット絵になる）
    static var available: Bool { Level.allCases.allSatisfy { base($0) != nil } }

    static func base(_ level: Level) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let img = bases[level] { return img }
        if missing { return nil }
        guard let url = url(level), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            missing = true
            AppLog.write("realistic mochi: image not found (\(level.rawValue)); using the pixel style")
            return nil
        }
        bases[level] = img
        boxes[level] = bodyBox(img)
        return img
    }

    /// 体のある範囲（マス、左下原点。不透明度が半分を超えるところ）
    static func box(_ level: Level) -> CGRect {
        lock.lock(); defer { lock.unlock() }
        if let b = boxes[level] { return b }
        _ = base(level)
        return boxes[level] ?? CGRect(x: 1, y: 1, width: 13, height: 5)
    }

    private static func bodyBox(_ img: CGImage) -> CGRect {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else {
            return CGRect(x: 1, y: 1, width: 13, height: 5)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return CGRect(x: 1, y: 1, width: 13, height: 5) }
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = data + y * w
            for x in 0..<w where row[x] > 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return CGRect(x: 1, y: 1, width: 13, height: 5) }
        // ctx のデータは上の行から（CGContext のビットマップは y が下向き）
        let c = sourceCell
        return CGRect(x: CGFloat(minX) / c, y: CGFloat(h - 1 - maxY) / c,
                      width: CGFloat(maxX - minX + 1) / c, height: CGFloat(maxY - minY + 1) / c)
    }

    // MARK: - 形

    static func level(_ p: JellyPose) -> Level {
        switch p.legs {
        case .crouch: return .flat
        case .dangle: return .rest
        default: break
        }
        switch max(-1, min(3, p.puff)) {
        case -1: return .flat
        case 1: return .puff1
        case 2: return .puff2
        case 3: return .puff3
        default: return .rest
        }
    }

    /// 元の絵に掛ける伸び縮み（足元の中心を基準）：つままれて「のび〜」、ぎゅっとつぶれる
    static func stretch(_ p: JellyPose) -> CGSize {
        switch p.legs {
        case .dangle: return CGSize(width: 0.56, height: 1.5)
        case .crouch: return CGSize(width: 1.0, height: 0.78)
        default: return CGSize(width: 1, height: 1)
        }
    }

    /// 床（10 行目の下の線）の高さ（マス、下から）と、キャンバスの中心
    static let floorY: CGFloat = 1
    static let centerX: CGFloat = CGFloat(MochiSprite.cols) / 2

    /// 目の高さ（床から、マス）。体を正面から少し見下ろしているので、顔は体の下のほう
    static func eyeHeight(_ level: Level) -> CGFloat {
        switch level {
        case .flat: return 1.55
        case .rest: return 2.15
        case .puff1: return 2.5
        case .puff2: return 2.8
        case .puff3: return 3.0
        }
    }

    /// 体の幅（マス）。床の影の大きさに使う
    static func bodyWidth(_ p: JellyPose) -> CGFloat { box(level(p)).width * stretch(p).width }

    // MARK: - 色

    /// 体に掛ける色。灰色（既定）のおもちはお餅そのままの白、ほかは淡い色のお餅に
    static func tint(_ colors: SpriteColors, tone: JellyPose.Tone) -> SIMD3<Double> {
        switch tone {
        case .error: return SIMD3(0.98, 0.55, 0.50)
        case .cancelled: return SIMD3(0.62, 0.61, 0.60)
        case .normal: break
        }
        let f = colors.flat
        let mx = max(f.x, f.y, f.z), mn = min(f.x, f.y, f.z)
        if mx - mn < 0.08 { return SIMD3(1, 1, 1) }
        return SIMD3(1, 1, 1) - (SIMD3(1, 1, 1) - f) * 0.62
    }

    private static var tinted: [String: CGImage] = [:]

    /// 元の絵に色を掛けたもの（陰影はそのまま）
    static func tintedBase(_ level: Level, colors: SpriteColors, key: String, tone: JellyPose.Tone) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let t = tint(colors, tone: tone)
        let k = "\(level.rawValue)|\(key)|\(tone)"
        if let img = tinted[k] { return img }
        guard let src = base(level) else { return nil }
        if t == SIMD3(1, 1, 1) { tinted[k] = src; return src }
        let w = src.width, h = src.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return src }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        // お餅の白（絵の平均くらい）を色に合わせる。premultiplied なので、そのまま掛けてよい
        let white = SIMD3<Double>(0.92, 0.91, 0.88)
        let gain = t / white
        for i in stride(from: 0, to: w * h * 4, by: 4) where data[i + 3] > 0 {
            data[i] = UInt8(min(Double(data[i + 3]), Double(data[i]) * gain.x))
            data[i + 1] = UInt8(min(Double(data[i + 3]), Double(data[i + 1]) * gain.y))
            data[i + 2] = UInt8(min(Double(data[i + 3]), Double(data[i + 2]) * gain.z))
        }
        guard let img = ctx.makeImage() else { return src }
        tinted[k] = img
        return img
    }

    // MARK: - 絵

    private static var cache: [String: CGImage] = [:]

    /// 体（目つき）の絵。px = 1 マスの出力ピクセル数
    static func body(_ pose: JellyPose, colors: SpriteColors, key: String, px: CGFloat) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let k = "body|\(key)|\(px)|\(pose.hashValue)"
        if let img = cache[k] { return img }
        let lv = level(pose)
        guard let base = tintedBase(lv, colors: colors, key: key, tone: pose.tone) else { return nil }
        let W = Int(CGFloat(MochiSprite.cols) * px), H = Int(CGFloat(MochiSprite.rows) * px)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // マス単位で描く（左下原点）
        ctx.scaleBy(x: px, y: px)
        let s = stretch(pose)
        let lift = CGFloat(pose.lift)
        ctx.saveGState()
        ctx.translateBy(x: centerX, y: floorY + lift)
        ctx.scaleBy(x: s.width, y: s.height)
        ctx.translateBy(x: -centerX, y: -floorY)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(MochiSprite.cols), height: CGFloat(MochiSprite.rows)))
        ctx.restoreGState()
        let b0 = box(lv)
        let bodyRect = CGRect(x: centerX + (b0.minX - centerX) * s.width, y: floorY + lift + (b0.minY - floorY) * s.height,
                              width: b0.width * s.width, height: b0.height * s.height)
        drawSurface(ctx, pose, body: bodyRect)

        // 目：体の正面、少し下。ふくらむと目の間も広がる
        let b = box(lv)
        let spread = b.width * s.width * 0.165
        let ey = floorY + lift + eyeHeight(lv) * s.height
        drawEyes(ctx, pose.eyes, at: [CGPoint(x: centerX - spread, y: ey), CGPoint(x: centerX + spread, y: ey)])

        guard let img = ctx.makeImage() else { return nil }
        if cache.count > 400 { cache.removeAll() }
        cache[k] = img
        return img
    }

    static let eyeColor = CGColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 1)

    /// 体の表面（あんこ・打ち粉・焦げ目・ひび・乾き）と頭のだいだい。体の上にだけ描く（sourceAtop）
    private static func drawSurface(_ ctx: CGContext, _ p: JellyPose, body r: CGRect) {
        guard p.anko || p.char > 0 || p.hard > 0 || p.crown else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func blob(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ rgb: SIMD3<Double>, _ a: CGFloat) {
            let g = CGGradient(colorSpace: space, colorComponents: [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), a,
                                                                     CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 0],
                               locations: [0, 1], count: 2)!
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: rx, y: ry)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.setBlendMode(.sourceAtop)
        // 乾いて白っぽく（硬い）
        if p.hard > 0 {
            ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.96, blue: 0.93, alpha: 0.16 * CGFloat(p.hard)))
            ctx.fill(r.insetBy(dx: -1, dy: -1))
        }
        // あんこ：上のほうに透ける、ぼんやりした濃いところ
        if p.anko {
            blob(CGPoint(x: r.midX, y: r.minY + r.height * 0.62), r.width * 0.24, r.height * 0.2, SpriteColors.ankoColor, 0.42)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
            for (dx, dy) in [(-0.3, 0.93), (-0.05, 0.97), (0.22, 0.9), (0.36, 0.84), (-0.4, 0.82), (0.08, 0.86)] as [(CGFloat, CGFloat)] {
                let c = CGPoint(x: r.midX + dx * r.width, y: r.minY + dy * r.height)
                ctx.fillEllipse(in: CGRect(x: c.x - 0.09, y: c.y - 0.09, width: 0.18, height: 0.18))
            }
        }
        // 焦げ目：上の面のこんがりした斑点
        if p.char > 0 {
            var spots: [(CGFloat, CGFloat, CGFloat, Bool)] = [(-0.22, 0.9, 0.11, false), (0.2, 0.86, 0.1, false), (0.02, 0.95, 0.07, false)]
            if p.char >= 2 {
                spots += [(-0.05, 0.92, 0.13, true), (-0.36, 0.72, 0.09, true), (0.36, 0.7, 0.1, false),
                          (-0.3, 0.12, 0.1, false), (0.28, 0.1, 0.11, true)]
            }
            for (dx, dy, rad, deep) in spots {
                blob(CGPoint(x: r.midX + dx * r.width, y: r.minY + dy * r.height), rad * r.width, rad * r.width * 0.55,
                     deep ? SpriteColors.charDeep : SpriteColors.char, p.char >= 2 ? 0.85 : 0.7)
            }
        }
        // ひび
        if p.hard > 0 {
            ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.32, blue: 0.3, alpha: 0.6))
            ctx.setLineWidth(0.09)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.78))
            ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.7))
            ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.6))
            if p.hard >= 2 {
                ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.32, y: r.minY + r.height * 0.52))
                ctx.move(to: CGPoint(x: r.maxX - r.width * 0.1, y: r.minY + r.height * 0.66))
                ctx.addLine(to: CGPoint(x: r.maxX - r.width * 0.18, y: r.minY + r.height * 0.58))
                ctx.addLine(to: CGPoint(x: r.maxX - r.width * 0.2, y: r.minY + r.height * 0.5))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
        // だいだい（体の外、上にのせる）
        if p.crown {
            let c = CGPoint(x: r.midX, y: r.maxY + 0.78)
            let g = CGGradient(colorSpace: space, colorComponents: [1.0, 0.72, 0.30, 1, 0.93, 0.46, 0.06, 1, 0.78, 0.34, 0.02, 1],
                               locations: [0, 0.6, 1], count: 3)!
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - 1.25, y: c.y - 0.95, width: 2.5, height: 1.9))
            ctx.clip()
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - 0.45, y: c.y + 0.4), startRadius: 0,
                                   endCenter: c, endRadius: 1.45, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setFillColor(CGColor(srgbRed: 0.28, green: 0.58, blue: 0.22, alpha: 1))
            ctx.translateBy(x: c.x + 0.32, y: c.y + 1.02)
            ctx.rotate(by: 0.5)
            ctx.fillEllipse(in: CGRect(x: -0.55, y: -0.19, width: 1.1, height: 0.38))
            ctx.restoreGState()
        }
    }

    private static func drawEyes(_ ctx: CGContext, _ eyes: JellyPose.Eyes, at centers: [CGPoint]) {
        ctx.saveGState()
        ctx.setFillColor(eyeColor)
        ctx.setStrokeColor(eyeColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(0.17)
        for c in centers {
            switch eyes {
            case .open(let dx, let dy):
                // 黒目（つやのある黒ごまくらい）と、左上の小さな光
                let p = CGPoint(x: c.x + CGFloat(dx) * 0.28, y: c.y - CGFloat(dy) * 0.26)
                ctx.fillEllipse(in: CGRect(x: p.x - 0.33, y: p.y - 0.46, width: 0.66, height: 0.92))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
                ctx.fillEllipse(in: CGRect(x: p.x - 0.21, y: p.y + 0.07, width: 0.22, height: 0.24))
                ctx.setFillColor(eyeColor)
            case .closed:
                // 閉じた目：下向きにゆるく曲がった線
                ctx.move(to: CGPoint(x: c.x - 0.36, y: c.y - 0.02))
                ctx.addQuadCurve(to: CGPoint(x: c.x + 0.36, y: c.y - 0.02), control: CGPoint(x: c.x, y: c.y - 0.30))
                ctx.strokePath()
            case .happy:
                // ^ ^
                ctx.move(to: CGPoint(x: c.x - 0.38, y: c.y - 0.18))
                ctx.addQuadCurve(to: CGPoint(x: c.x + 0.38, y: c.y - 0.18), control: CGPoint(x: c.x, y: c.y + 0.42))
                ctx.strokePath()
            case .cross:
                let d: CGFloat = 0.28
                ctx.move(to: CGPoint(x: c.x - d, y: c.y - d)); ctx.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
                ctx.move(to: CGPoint(x: c.x - d, y: c.y + d)); ctx.addLine(to: CGPoint(x: c.x + d, y: c.y - d))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// 頭上の「…」「!」「✓」（ドット絵と同じ場所に、なめらかな形で）
    static func marks(_ pose: JellyPose, colors: SpriteColors, key: String, px: CGFloat) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if pose.mark == .none { return nil }
        let k = "marks|\(key)|\(px)|\(pose.mark)"
        if let img = cache[k] { return img }
        let W = Int(CGFloat(MochiSprite.cols) * px), H = Int(CGFloat(MochiSprite.rows) * px)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: px, y: px)
        let rows = CGFloat(MochiSprite.rows)
        // 上からのマス → 左下原点
        func pt(_ x: CGFloat, _ yFromTop: CGFloat) -> CGPoint { CGPoint(x: x, y: rows - yFromTop) }
        func cg(_ v: SIMD3<Double>) -> CGColor { CGColor(srgbRed: v.x, green: v.y, blue: v.z, alpha: 1) }
        let markColor = cg(colors.color(.mark, tone: .normal))
        // 明るい背景でも暗い背景でも見えるよう、うすい影を付ける
        ctx.setShadow(offset: CGSize(width: 0, height: -0.06), blur: 0.25, color: CGColor(gray: 0, alpha: 0.35))
        switch pose.mark {
        case .none: break
        case .dots(let n):
            ctx.setFillColor(markColor)
            for i in 0..<min(n, 3) {
                let c = pt(5.5 + CGFloat(i) * 2, 1.5)
                ctx.fillEllipse(in: CGRect(x: c.x - 0.42, y: c.y - 0.42, width: 0.84, height: 0.84))
            }
        case .exclaim:
            ctx.setFillColor(cg(SpriteColors.warn))
            let top = pt(13, 0.15), bottom = pt(13, 1.75)
            ctx.addPath(CGPath(roundedRect: CGRect(x: top.x - 0.36, y: bottom.y, width: 0.72, height: top.y - bottom.y),
                               cornerWidth: 0.34, cornerHeight: 0.34, transform: nil))
            ctx.fillPath()
            let d = pt(13, 2.6)
            ctx.fillEllipse(in: CGRect(x: d.x - 0.38, y: d.y - 0.38, width: 0.76, height: 0.76))
        case .steam(let phase):
            // 湯気：3 本のゆらゆらした白い線
            ctx.setStrokeColor(CGColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 0.9))
            ctx.setLineWidth(0.32)
            ctx.setLineCap(.round)
            for (k, x0) in [5.2, 7.5, 9.8].enumerated() {
                let sway = CGFloat((phase + k) % 2 == 0 ? 0.35 : -0.35)
                let x = CGFloat(x0)
                ctx.move(to: pt(x, 2.9))
                ctx.addCurve(to: pt(x, 0.3), control1: pt(x + sway, 2.0), control2: pt(x - sway, 1.2))
                ctx.strokePath()
            }
        case .check:
            ctx.setStrokeColor(markColor)
            ctx.setLineWidth(0.62)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: pt(11.7, 1.75))
            ctx.addLine(to: pt(12.75, 2.75))
            ctx.addLine(to: pt(14.7, 0.65))
            ctx.strokePath()
        }
        guard let img = ctx.makeImage() else { return nil }
        if cache.count > 400 { cache.removeAll() }
        cache[k] = img
        return img
    }

    /// 床の影（ぼかした楕円）
    static let shadowImage: CGImage? = {
        let w = 128, h = 32
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let g = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colorComponents: [0, 0, 0, 0.42, 0, 0, 0, 0.22, 0, 0, 0, 0], locations: [0, 0.55, 1], count: 3)!
        ctx.scaleBy(x: CGFloat(w) / CGFloat(h), y: 1)
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: CGFloat(h) / 2, y: CGFloat(h) / 2), startRadius: 0,
                               endCenter: CGPoint(x: CGFloat(h) / 2, y: CGFloat(h) / 2), endRadius: CGFloat(h) / 2, options: [])
        return ctx.makeImage()
    }()
}
