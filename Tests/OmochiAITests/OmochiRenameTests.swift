import Foundation
import Testing
@testable import OmochiAI

// 名前を Jellyfish AI から OMOCHI AI に変えたときの引き継ぎと、リアルなおもちの絵のテスト

@Suite struct LegacyMigrationTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("omochi-mig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 前のフォルダ（おもちの記録・設定・会話・ソケット・ロック）を作る
    private func makeLegacy(in base: URL) throws -> URL {
        let old = base.appendingPathComponent(LegacyMigration.legacyFolderName, isDirectory: true)
        let agent = old.appendingPathComponent("agents/A1", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try #"[{"id":"A1","number":1}]"#.write(to: old.appendingPathComponent("jellies.json"), atomically: true, encoding: .utf8)
        try #"{"launchAtLogin":true}"#.write(to: old.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try ".".write(to: old.appendingPathComponent(".instance.lock"), atomically: true, encoding: .utf8)
        let history = #"[{"prompt":"[Jellyfish チーム依頼 from: おもち 2]\nやって","tools":["mcp__jellyfish__screen_capture"],"#
            + #""note":"見て\n\n---\n[Jellyfish 画面コンテキスト]\n画面"}]"#
        try history.write(to: agent.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
        // 動いていたアプリのソケット（名前で外す）と、普通のファイルでないもの（シンボリックリンク。写さない）
        try "".write(to: old.appendingPathComponent("bus.sock"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: agent.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        return old
    }

    @Test func copiesTheOldFolderAndRenamesWhatTheChatsRemember() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = try makeLegacy(in: base)
        let new = base.appendingPathComponent(AppPaths.folderName, isDirectory: true)
        #expect(LegacyMigration.needed(new: new, old: old))

        try LegacyMigration.copy(from: old, to: new)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: new.appendingPathComponent("jellies.json").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("settings.json").path))
        // ロックとソケットは写さない
        #expect(!fm.fileExists(atPath: new.appendingPathComponent(".instance.lock").path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("bus.sock").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: new.appendingPathComponent("agents/A1/link").path)) == nil)
        // 前のフォルダは残す
        #expect(fm.fileExists(atPath: old.appendingPathComponent("jellies.json").path))

        let h = try String(contentsOf: new.appendingPathComponent("agents/A1/history.json"), encoding: .utf8)
        #expect(!h.contains("Jellyfish") && !h.contains("jellyfish"))
        #expect(h.contains(TeamCoordinator.requestMarker))
        #expect(h.contains("mcp__omochi__screen_capture"))
        // 写した会話の目印を、チャットの表示が今の目印として見つけられる
        let note = "見て" + ScreenContext.marker + "\n画面"
        #expect(h.contains(note.replacingOccurrences(of: "\n", with: "\\n")))
        // 写したあとはもう要らない
        #expect(!LegacyMigration.needed(new: new, old: old))
        // 新しいフォルダに途中の一時フォルダが残らない
        let leftovers = try fm.contentsOfDirectory(atPath: base.path).filter { $0.contains("migrating") }
        #expect(leftovers.isEmpty)
    }

    @Test func doesNothingWithoutAnOldFolderOrWhenTheNewOneIsInUse() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent(LegacyMigration.legacyFolderName, isDirectory: true)
        let new = base.appendingPathComponent(AppPaths.folderName, isDirectory: true)
        #expect(!LegacyMigration.needed(new: new, old: old))

        _ = try makeLegacy(in: base)
        // ログだけの新しいフォルダ（引き継ぐ前に書かれたもの）なら、まだ引き継ぐ
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try "log".write(to: new.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)
        #expect(LegacyMigration.needed(new: new, old: old))
        // おもちの記録がある新しいフォルダは上書きしない
        try "[]".write(to: new.appendingPathComponent("jellies.json"), atomically: true, encoding: .utf8)
        #expect(!LegacyMigration.needed(new: new, old: old))
    }

    @Test func theOldNamesStayOnlyWhereTheyAreNeeded() {
        #expect(Bundle.main.bundleIdentifier != LegacyMigration.legacyBundleID)
        #expect(TeamCoordinator.requestMarker.hasPrefix("[OMOCHI AI "))
        #expect(ScreenContext.marker.contains("[OMOCHI AI "))
        #expect(AppPaths.folderName == "OmochiAI")
    }
}

@Suite struct RealMochiArtTests {
    @Test func everyShapeHasItsPictureStandingOnTheFloor() throws {
        #expect(RealMochiArt.available)
        for lv in RealMochiArt.Level.allCases {
            let b = RealMochiArt.box(lv)
            // ドット絵と同じ床（下から 1 マス）に立ち、キャンバスからはみ出さない
            #expect(abs(b.minY - RealMochiArt.floorY) < 0.1, "\(lv) floor \(b.minY)")
            #expect(b.minX >= 0 && b.maxX <= CGFloat(MochiSprite.cols))
            #expect(b.maxY <= CGFloat(MochiSprite.rows))
        }
        // ふくらむほど背が高い
        let heights = [RealMochiArt.Level.rest, .puff1, .puff2, .puff3].map { RealMochiArt.box($0).height }
        #expect(heights == heights.sorted())
        // 休んでいる形はドット絵と同じ 13 マスの幅
        #expect(abs(RealMochiArt.box(.rest).width - 13) < 0.2)
    }

    @Test func drawsEveryPoseAtTheCanvasSize() throws {
        let jc = Palette.color(1)
        let colors = SpriteColors.from(jc)
        for (_, pose) in SnapshotTool.pixelPoses() {
            let img = try #require(RealMochiArt.body(pose, colors: colors, key: jc.key, px: 12))
            #expect(img.width == MochiSprite.cols * 12 && img.height == MochiSprite.rows * 12)
            #expect((RealMochiArt.marks(pose, colors: colors, key: jc.key, px: 12) == nil) == (pose.mark == .none))
        }
    }

    @Test func grayMochiStaysRiceWhiteAndOthersArePastel() {
        let gray = SpriteColors.from(Palette.color(0))
        #expect(RealMochiArt.tint(gray, tone: .normal) == SIMD3(1, 1, 1))
        let blue = RealMochiArt.tint(SpriteColors.from(Palette.color(1)), tone: .normal)
        #expect(blue.z > blue.x && blue.x > 0.5)
        let err = RealMochiArt.tint(gray, tone: .error)
        #expect(err.x > err.y && err.x > err.z)
    }

    @Test func realisticStyleUsesTheSameLayoutAsPixel() {
        let a = AvatarFactory.layout(.pixel, scale: 1.25), b = AvatarFactory.layout(.realistic, scale: 1.25)
        #expect(a.size == b.size && a.stepX == b.stepX && a.stepY == b.stepY)
        #expect(AvatarStyle.realistic.label != AvatarStyle.pixel.label)
    }
}
