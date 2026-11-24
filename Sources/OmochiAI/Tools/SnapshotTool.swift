import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ウィンドウを出さずにおもちを PNG に描き出す開発用ツール。
///   --sheet out.png [--bg dark|light]        リアルなおもちの 色 × 形・表情 の一覧
///   --pixel-sheet out.png [--bg dark|light]  ドット絵のおもちの 色 × 形・表情 の一覧
///   --icon out.png [--icon-source art.png]   アプリアイコン (1024px)。art を角丸の枠に収める（無ければおもちのドット絵を描く）
///   --account-menu out.png                   メニューのアカウントと使用量の欄（実際に claude から読む。明暗 2 つ並べる）
///   --connectors-window out.png [--preset p] [--bg dark|light]   🔌 コネクタの画面（ワンタッチ設定 p の内容で。画面には出さずに描く）
enum SnapshotTool {
    static func handles(_ args: [String]) -> Bool {
        args.contains("--sheet") || args.contains("--icon") || args.contains("--status-frames")
            || args.contains("--pixel-sheet") || args.contains("--account-menu") || args.contains("--connectors-window") || args.contains("--chat-sample") || args.contains("--watch-bench")
    }

    static func run(_ args: [String]) -> Int32 {
        func value(_ k: String) -> String? {
            guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let out = value("--sheet") { return pixelSheet(out, dark: value("--bg") != "light", art: .real) }
        if let out = value("--connectors-window") { return connectorsWindow(out, preset: value("--preset"), dark: value("--bg") != "light") }
        if let out = value("--pixel-sheet") { return pixelSheet(out, dark: value("--bg") != "light", art: .pixel) }
        if let out = value("--icon") { return icon(out, source: value("--icon-source")) }
        if let out = value("--status-frames") { return statusFrames(out) }
        if let out = value("--account-menu") { return accountMenu(out) }
        if let out = value("--chat-sample") { return chatSample(out, dark: value("--bg") == "dark") }
        if let s = value("--watch-bench").flatMap(Double.init) {
            // 見守りの負担を測る：毎回読む場合と、変わったときだけ読む場合（どちらも Mac の中だけ・モデルは呼ばない）
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                print(await ScreenWatcher.bench(seconds: s, force: true))
                print(await ScreenWatcher.bench(seconds: s, force: false))
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return 0
        }
        return 1
    }

    // MARK: - チャットの表示の見本（表・数式・図・コード）。画面の外の窓で描いて PNG に（モデルは呼ばない・前面に出さない）

    static func chatSample(_ out: String, dark: Bool) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = NSRect(x: 0, y: 0, width: 760, height: 1900)
        let w = NSWindow(contentRect: size.offsetBy(dx: -6000, dy: -6000), styleMask: [.borderless], backing: .buffered, defer: false)
        let bg = NSVisualEffectView(frame: size)
        bg.material = .windowBackground
        bg.state = .active
        w.contentView = bg
        let v = ChatTranscriptView(frame: size)
        v.autoresizingMask = [.width, .height]
        bg.addSubview(v)
        w.orderFrontRegardless()
        let answer = """
        ## 四季の詩の比べ方

        | 季節 | 題 | 字数 | 評価 |
        |---|---|---:|:---:|
        | 春 | 霞の朝 | 31 | ★★★ |
        | 夏 | 蝉しぐれ | 28 | ★★☆ |
        | 秋 | 月の舟 | 33 | ★★★ |
        | 冬 | 雪明かり | 30 | ★★☆ |

        点数は $s = \\frac{1}{n}\\sum_{i=1}^{n} w_i x_i$ で、重みは $\\sum w_i = 1$ です。

        $$
        \\int_0^{2\\pi} \\sin^2\\theta\\,d\\theta = \\pi, \\qquad e^{i\\pi} + 1 = 0
        $$

        ```mermaid
        pie title 票の割合
          "春" : 34
          "夏" : 18
          "秋" : 31
          "冬" : 17
        ```

        ```mermaid
        xychart-beta
          title "季節ごとの点数"
          x-axis ["春", "夏", "秋", "冬"]
          y-axis "点数" 0 --> 100
          bar [82, 64, 88, 70]
          line [82, 64, 88, 70]
        ```

        ```mermaid
        flowchart LR
          A[依頼] --> B{分担する？}
          B -- はい --> C[仲間を作る]
          B -- いいえ --> D[一人で]
          C --> E[レビュー係が選ぶ]
        ```

        ```swift
        let best = poems.max { $0.score < $1.score }
        print(best?.title ?? "なし")
        ```

        値段の $5 と $10 は数式になりません。詳しくは [Mermaid の書き方](https://mermaid.js.org) を見てください。
        """
        let payload: [String: Any] = [
            "accent": "#B8B5B0",
            "items": [
                ["id": "u", "kind": "user", "caption": L("あなた"), "captionStyle": "muted", "text": "四季の詩を比べて、表・数式・グラフで見せて"],
                ["id": "t", "kind": "tool", "text": "⚙︎ Bash: python3 score.py"],
                ["id": "a", "kind": "assistant", "caption": "Claude", "captionColor": "#B8B5B0", "text": answer],
                ["id": "u2", "kind": "user", "caption": L("あなた"), "captionStyle": "muted", "text": "いちばん点の高い詩を、英語にもして"],
                ["id": "a2", "kind": "assistant", "caption": "Claude", "captionColor": "#B8B5B0", "text": "「月の舟」を英語にしました。\n\n> A boat of moonlight drifts across the autumn sky."],
                ["id": "r", "kind": "request", "caption": "📨 Mio からの依頼", "captionColor": "#5B8DEF", "text": "この詩を 3 行に縮めて、結果を返してください"],
                ["id": "a3", "kind": "assistant", "caption": "Claude", "captionColor": "#B8B5B0", "text": "月の舟 / 秋の空を / わたる"],
            ],
            "labels": ["copy": L("コピー"), "copied": L("コピーしました"), "diagramFailed": L("図にできませんでした（Mermaid の書き方を確かめてください）")],
        ]
        v.update(payload, scrollToEnd: false)
        let until = Date().addingTimeInterval(6)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        var done = false
        var code: Int32 = 1
        v.web.takeSnapshot(with: nil) { img, err in
            if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                code = (try? png.write(to: URL(fileURLWithPath: out))) != nil ? 0 : 1
            } else {
                FileHandle.standardError.write(Data("snapshot failed: \(String(describing: err))\n".utf8))
            }
            done = true
        }
        let limit = Date().addingTimeInterval(10)
        while !done && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return code
    }

    // MARK: -

    static func makeContext(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    static func fillBackground(_ ctx: CGContext, _ rect: CGRect, dark: Bool) {
        let colors: [CGFloat] = dark ? [0.05, 0.07, 0.11, 1, 0.02, 0.03, 0.05, 1] : [0.95, 0.95, 0.97, 1, 0.86, 0.88, 0.91, 1]
        let g = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colorComponents: colors, locations: [0, 1], count: 2)!
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    static func write(_ img: CGImage, _ path: String) -> Int32 {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? 0 : 1
    }

    // MARK: - pixel sheet（ドット絵のコマ一覧）

    static func pixelPoses() -> [(String, JellyPose)] {
        var a: [(String, JellyPose)] = []
        a.append(("idle", JellyPose()))
        a.append(("puff3", { var p = JellyPose(); p.puff = 3; return p }()))
        a.append(("deflate", { var p = JellyPose(); p.puff = -1; return p }()))
        a.append(("blink", JellyPose(eyes: .closed)))
        a.append(("glance", JellyPose(eyes: .open(dx: 1, dy: -1))))
        a.append(("think1", JellyPose(eyes: .open(dx: -1, dy: -1), mark: .dots(1))))
        a.append(("think3", JellyPose(eyes: .open(dx: 1, dy: -1), mark: .dots(3))))
        a.append(("work1", JellyPose(eyes: .open(dx: 0, dy: 1), arms: .leftUp, legs: .walkA)))
        a.append(("work2", JellyPose(eyes: .open(dx: 0, dy: 1), arms: .rightUp, legs: .walkB)))
        a.append(("crouch", JellyPose(arms: .down, legs: .crouch)))
        a.append(("hop", JellyPose(arms: .rightUp, legs: .walkA, lift: 1)))
        a.append(("done", JellyPose(eyes: .happy, mark: .check)))
        a.append(("error", JellyPose(eyes: .cross, mark: .exclaim, tone: .error)))
        a.append(("cancel", JellyPose(eyes: .closed, tone: .cancelled)))
        a.append(("drag", JellyPose(eyes: .open(dx: 0, dy: 1), arms: .raised, legs: .dangle)))
        return a
    }

    static func pixelSheet(_ out: String, dark: Bool, art: MochiAvatar.Art) -> Int32 {
        if art == .real, !RealMochiArt.available {
            FileHandle.standardError.write("Resources/mochi の絵が見つかりません\n".data(using: .utf8)!)
            return 1
        }
        let poses = pixelPoses()
        let colorsN = 6
        // リアルな絵は大きめに（細部が見えるように）
        let scale = art == .real ? 4.0 : 2.0
        let P = CGFloat(MochiAvatar.cell(scale: 1.0) * scale)       // 1 マスの px
        let tileW = Int(CGFloat(MochiSprite.cols) * P), tileH = Int(CGFloat(MochiSprite.rows + 1) * P)
        let W = tileW * poses.count, H = tileH * colorsN
        let ctx = makeContext(W, H)
        fillBackground(ctx, CGRect(x: 0, y: 0, width: W, height: H), dark: dark)
        ctx.interpolationQuality = art == .real ? .high : .none
        for ci in 0..<colorsN {
            let jc = Palette.color(ci)
            let colors = SpriteColors.from(jc)
            for (i, (_, pose)) in poses.enumerated() {
                let rect = CGRect(x: CGFloat(i * tileW), y: CGFloat(H - (ci + 1) * tileH) + P * 0.5,
                                  width: CGFloat(MochiSprite.cols) * P, height: CGFloat(MochiSprite.rows) * P)
                if art == .real {
                    // 床の影（アプリと同じぼかした楕円）→ 体 → 頭上の記号
                    let w = RealMochiArt.bodyWidth(pose) * (pose.lift > 0 ? 0.7 : 0.94) * P
                    if let sh = RealMochiArt.shadowImage {
                        ctx.draw(sh, in: CGRect(x: rect.midX - w / 2, y: rect.minY + P * 0.55, width: w, height: P * 0.9))
                    }
                    if let body = RealMochiArt.body(pose, colors: colors, key: jc.key, px: P) { ctx.draw(body, in: rect) }
                    if let m = RealMochiArt.marks(pose, colors: colors, key: jc.key, px: P) { ctx.draw(m, in: rect) }
                } else {
                    // お餅は光らせない（足元の影は絵に入っている）
                    ctx.draw(MochiSprite.image(pose, colors: colors, key: jc.key), in: rect)
                }
            }
        }
        return write(ctx.makeImage()!, out)
    }

    // MARK: - icon

    /// macOS のアイコンの枠（1024 の中に 824 の角丸）。この形なら macOS 26 でも灰色の枠に入れられず、縁の光と影はシステムが付ける
    static func icon(_ out: String, source: String? = nil) -> Int32 {
        let S = 1024
        let ctx = makeContext(S, S)
        let inset: CGFloat = 100
        let rect = CGRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
        let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let source {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
                  let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                FileHandle.standardError.write("cannot read icon source: \(source)\n".data(using: .utf8)!)
                return 1
            }
            // 枠いっぱいに（縦横比を保って短い辺に合わせ、はみ出た分は切る）
            let k = max(rect.width / CGFloat(art.width), rect.height / CGFloat(art.height))
            let w = CGFloat(art.width) * k, h = CGFloat(art.height) * k
            ctx.interpolationQuality = .high
            ctx.draw(art, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            ctx.restoreGState()
            return write(ctx.makeImage()!, out)
        }
        let g = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colorComponents: [0.05, 0.13, 0.24, 1, 0.01, 0.03, 0.08, 1], locations: [0, 1], count: 2)!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 512), endRadius: 560, options: [.drawsAfterEndLocation])
        // Claude キャラクターを大きく描く（ドット絵なので補間なし）
        let jc = Palette.color(0)
        let img = MochiSprite.image(JellyPose(), colors: SpriteColors.from(jc), key: jc.key)
        let P: CGFloat = 52
        let w = CGFloat(MochiSprite.cols) * P, h = CGFloat(MochiSprite.rows) * P
        ctx.interpolationQuality = .none
        ctx.setShadow(offset: .zero, blur: 70, color: CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.6))
        ctx.draw(img, in: CGRect(x: (CGFloat(S) - w) / 2, y: (CGFloat(S) - h) / 2 - P * 0.6, width: w, height: h))
        ctx.restoreGState()
        return write(ctx.makeImage()!, out)
    }

    // MARK: - account menu

    static func accountMenu(_ out: String) -> Int32 {
        let (snap, _) = ClaudeAccount.fetch(override: nil, skipUsageFor: nil)
        print("limits: \(snap.limits.map { "\($0.label) \($0.percent)%" }.joined(separator: ", "))  note: \(snap.note ?? "-")  plan: \(snap.account?.plan ?? "-")")
        let w = AccountMenu.width, pad: CGFloat = 8, gap: CGFloat = 20
        var panels: [NSBitmapImageRep] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            // 実際のメニューと同じく、縦に積んだビューを AppKit に描かせる（isFlipped の文字の向きもそのまま）
            let views = AccountMenu.items(snap, loading: false).compactMap(\.view)
            let h = views.reduce(0) { $0 + $1.frame.height } + pad * 2
            let panel = NSBox(frame: NSRect(x: 0, y: 0, width: w, height: h))
            panel.boxType = .custom
            panel.borderWidth = 0
            panel.cornerRadius = 10
            panel.fillColor = .windowBackgroundColor
            panel.contentViewMargins = .zero
            panel.appearance = NSAppearance(named: name)
            var y = h - pad
            for v in views {
                y -= v.frame.height
                v.frame = NSRect(x: 0, y: y, width: w, height: v.frame.height)
                panel.addSubview(v)
            }
            guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { return 1 }
            panel.cacheDisplay(in: panel.bounds, to: rep)
            panels.append(rep)
        }
        let W = panels.reduce(0) { $0 + $1.pixelsWide } + Int(gap * 2)
        let H = panels.map(\.pixelsHigh).max() ?? 0
        let ctx = makeContext(W, H)
        var x = 0
        for p in panels {
            if let cg = p.cgImage { ctx.draw(cg, in: CGRect(x: x, y: H - p.pixelsHigh, width: p.pixelsWide, height: p.pixelsHigh)) }
            x += p.pixelsWide + Int(gap * 2)
        }
        return write(ctx.makeImage()!, out)
    }

    // MARK: - connectors window

    static func connectorsWindow(_ out: String, preset: String?, dark: Bool) -> Int32 {
        _ = NSApplication.shared
        let c = ConnectorsWindowController(manager: nil, preview: (preset.flatMap(ConnectorPreset.init(rawValue:)) ?? .recommended).settings)
        c.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        c.rebuild()
        guard let v = c.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return 1 }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let img = rep.cgImage else { return 1 }
        let ctx = makeContext(img.width, img.height)
        ctx.setFillColor(dark ? CGColor(gray: 0.15, alpha: 1) : CGColor(gray: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return write(ctx.makeImage()!, out)
    }

    /// メニューバーのアイコンのコマを並べた画像（確認用）
    static func statusFrames(_ out: String) -> Int32 {
        typealias P = MenuImages.StatusPose
        let poses: [P] = [P(), P(puff: 1), P(puff: 2), P(blink: true), P(puff: 1, dots: 1), P(puff: 3, dots: 3),
                          P(puff: -1), P(lift: 1, puff: 2)]
        let scale: CGFloat = 4, cell: CGFloat = 23 * scale, cellH: CGFloat = 18 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell) * poses.count, pixelsHigh: Int(cellH) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, bg) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.15, alpha: 1)].enumerated() {
            bg.setFill()
            NSRect(x: 0, y: CGFloat(row) * cellH, width: cell * CGFloat(poses.count), height: cellH).fill()
            for (i, p) in poses.enumerated() {
                let img = MenuImages.statusFrame(p).copy() as! NSImage
                img.isTemplate = false
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r)
                    (row == 0 ? NSColor.black : NSColor.white).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: CGFloat(i) * cell, y: CGFloat(row) * cellH, width: cell, height: cellH))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        return 0
    }
}
