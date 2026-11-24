import AppKit

/// 前の名前（Jellyfish AI）からの引き継ぎ。
///
/// 名前を OMOCHI AI に変えたときに、バンドル ID（ai.jellyfish.desktop → ai.omochi.desktop）と
/// データフォルダ（~/Library/Application Support/JellyfishAI → OmochiAI）も変えた。
/// 初めて OMOCHI AI を開いたとき（新しいフォルダがまだ無く、前のフォルダがあるとき）に 1 回だけ、
/// おもち・設定・会話を新しいフォルダへ写す。前のフォルダは消さない（前のアプリに戻っても使える）。
/// macOS の許可はアプリ（バンドル ID）ごとなので引き継げない。付け直してもらう
enum LegacyMigration {
    static let legacyBundleID = "ai.jellyfish.desktop"
    static let legacyFolderName = "JellyfishAI"

    /// 会話の記録に残っている、前の名前の目印とツールの名前（写したあとで今の名前にする）
    static let rewrites: [(String, String)] = [
        ("[Jellyfish チーム依頼 from: ", TeamCoordinator.requestMarker),
        ("[Jellyfish 画面コンテキスト]", "[OMOCHI AI 画面コンテキスト]"),
        ("mcp__jellyfish__", "mcp__omochi__"),
    ]

    /// 写さないもの（動いていたアプリのソケットとロック）
    static let skipped: Set<String> = ["bus.sock", ".instance.lock"]

    enum Outcome { case nothing, migrated, quit }

    static func legacyDir(base: URL = AppPaths.defaultDir.deletingLastPathComponent()) -> URL {
        base.appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// 写す必要があるか：新しいフォルダが無く（または中身が無く）、前のフォルダにおもちの記録がある
    static func needed(new: URL, old: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.appendingPathComponent("jellies.json").path)
                || fm.fileExists(atPath: old.appendingPathComponent("settings.json").path) else { return false }
        guard fm.fileExists(atPath: new.path) else { return true }
        let items = (try? fm.contentsOfDirectory(atPath: new.path)) ?? []
        return items.allSatisfy { skipped.contains($0) || $0 == "app.log" || $0 == ".DS_Store" }
    }

    /// GUI の起動の最初（データフォルダを使う前）に呼ぶ。
    /// .quit：前のアプリを終えずに閉じることにした（何も作らないので、次に開いたときにまた聞く）
    static func runIfNeeded() -> Outcome {
        guard !AppPaths.overridden else { return .nothing }
        let new = AppPaths.defaultDir, old = legacyDir()
        guard needed(new: new, old: old) else { return .nothing }

        // 前のアプリが動いていれば、終えてから写す（終了の処理でおもちの位置や会話を保存する）
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID)
        if !running.isEmpty {
            let a = NSAlert()
            a.messageText = L("Jellyfish AI が動いています")
            a.informativeText = L("Jellyfish AI は OMOCHI AI に名前が変わりました。おもち・設定・会話を引き継ぐため、Jellyfish AI を終了します（作業中のエージェントは中断されます）。")
            a.addButton(withTitle: L("終了して引き継ぐ"))
            a.addButton(withTitle: L("OMOCHI AI を閉じる"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return .quit }
            running.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if running.contains(where: { !$0.isTerminated }) {
                let f = NSAlert()
                f.messageText = L("Jellyfish AI が終わりませんでした")
                f.informativeText = L("メニューバーから Jellyfish AI を終了してから、OMOCHI AI をもう一度開いてください。")
                f.runModal()
                return .quit
            }
        }

        do {
            try copy(from: old, to: new)
        } catch {
            NSLog("OMOCHI AI: migration from \(old.path) failed: \(error)")
            let f = NSAlert()
            f.messageText = L("Jellyfish AI から引き継げませんでした")
            f.informativeText = L("前のデータはそのまま残っています（%@）。新しく始めます。", old.path) + "\n\n" + error.localizedDescription
            f.runModal()
            return .nothing
        }
        AppLog.write("migrated from \(old.path)")
        offerToTrashLegacyApp()
        return .migrated
    }

    /// 前のフォルダの中身を写して（普通のファイルとフォルダだけ）、会話の記録の前の名前を直す。
    /// 一時的な場所に写してから名前を変えるので、途中で失敗しても半端なフォルダは残らない
    static func copy(from old: URL, to new: URL) throws {
        let fm = FileManager.default
        let tmp = new.deletingLastPathComponent()
            .appendingPathComponent(".\(new.lastPathComponent)-migrating-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try copyTree(old, tmp, top: true)
            rewriteHistories(in: tmp)
            // 中身の無い新しいフォルダ（ログだけ）があれば置き換える
            if fm.fileExists(atPath: new.path) { try fm.removeItem(at: new) }
            try fm.moveItem(at: tmp, to: new)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    private static func copyTree(_ src: URL, _ dst: URL, top: Bool) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            if top && skipped.contains(name) { continue }
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            let type = (try? fm.attributesOfItem(atPath: s.path))?[.type] as? FileAttributeType
            switch type {
            case .typeDirectory?:
                try fm.createDirectory(at: d, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: (try? fm.attributesOfItem(atPath: s.path))?[.posixPermissions] ?? 0o700])
                try copyTree(s, d, top: false)
            case .typeRegular?:
                try fm.copyItem(at: s, to: d)
            default:
                continue  // ソケット・シンボリックリンクなどは写さない
            }
        }
    }

    /// agents/<id>/history.json の前の名前（チームの依頼・画面の目印、ツールの名前）を今の名前にする
    static func rewriteHistories(in dir: URL) {
        let agents = dir.appendingPathComponent("agents", isDirectory: true)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? []
        for id in ids {
            let url = agents.appendingPathComponent(id).appendingPathComponent("history.json")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var t = text
            for (a, b) in rewrites { t = t.replacingOccurrences(of: a, with: b) }
            if t != text { try? t.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// 前のアプリはもう使わないので、ゴミ箱に入れるかを聞く（残すとログイン時に前のアプリも開いてしまう）
    private static func offerToTrashLegacyApp() {
        let a = NSAlert()
        a.messageText = L("Jellyfish AI から引き継ぎました")
        var text = L("おもち・設定・会話を OMOCHI AI に写しました（前のデータフォルダはそのまま残しています）。")
            + "\n\n" + L("名前が変わったので、macOS の許可（アクセシビリティ・画面収録など）は付け直しが必要です。メニューバーのおもち › 🔐 権限 から付けられます。")
        let oldApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: legacyBundleID)
        if let oldApp {
            text += "\n\n" + L("前の Jellyfish AI のアプリ（%@）はもう使いません。ゴミ箱に入れますか？", oldApp.path)
            a.addButton(withTitle: L("ゴミ箱に入れる"))
            a.addButton(withTitle: L("そのままにする"))
        } else {
            a.addButton(withTitle: L("OK"))
        }
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn, let oldApp else { return }
        NSWorkspace.shared.recycle([oldApp]) { _, error in
            if let error { AppLog.write("could not trash \(oldApp.path): \(error.localizedDescription)") }
        }
    }
}
