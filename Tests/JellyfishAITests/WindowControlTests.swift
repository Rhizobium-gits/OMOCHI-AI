import AppKit
import Foundation
import Testing
@testable import JellyfishAI

// チャットの窓で、閉じる・しまう・フル画面の操作ができ、どこからでも戻れること（1.2.3）。
// クラゲを消したあとメニューバーからチャットを開くと、アプリが「Dock に出ないアプリ」（accessory = Dock に出ず、
// メニューバーも持たない）のまま窓を出していたので、⌘W・⌘M・⌃⌘F が効かず、隠れたりしまったりすると戻れなかった

@Suite(.serialized) struct WindowControlTests {
    /// メニューの並びと名前・ショートカットが、Apple の HIG（The menu bar）と macOS のアプリと同じ
    @Test @MainActor func menusFollowTheHIG() throws {
        let app = NSApplication.shared
        let saved = (app.mainMenu, app.windowsMenu)
        defer { app.mainMenu = saved.0; app.windowsMenu = saved.1 }
        AppDelegate().installMainMenu()
        let main = try #require(app.mainMenu)
        #expect(main.items.map(\.title) == ["Jellyfish AI", "ファイル", "編集", "表示", "ウインドウ"])
        func menu(_ title: String) throws -> NSMenu { try #require(main.items.first { $0.title == title }?.submenu) }
        func find(_ m: NSMenu, _ action: Selector) -> NSMenuItem? { m.items.first { $0.action == action } }

        let appMenu = try menu("Jellyfish AI")
        #expect(find(appMenu, #selector(NSApplication.hide(_:)))?.keyEquivalent == "h")
        let others = try #require(find(appMenu, #selector(NSApplication.hideOtherApplications(_:))))
        #expect(others.keyEquivalent == "h" && others.keyEquivalentModifierMask == [.command, .option])
        #expect(find(appMenu, #selector(NSApplication.unhideAllApplications(_:))) != nil)
        #expect(find(appMenu, #selector(NSApplication.terminate(_:)))?.keyEquivalent == "q")

        // 閉じるは「ファイル」（⌘W）
        let close = try #require(find(try menu("ファイル"), #selector(NSWindow.performClose(_:))))
        #expect(close.keyEquivalent == "w" && close.keyEquivalentModifierMask == [.command])

        // フルスクリーンは「表示」（⌃⌘F）
        let view = try menu("表示")
        let fs = try #require(find(view, #selector(AppDelegate.toggleFullScreenOfFrontWindow(_:))))
        #expect(fs.keyEquivalent == "f" && fs.keyEquivalentModifierMask == [.command, .control])

        // しまう（⌘M）・拡大／縮小・すべてを手前に移動は「ウインドウ」。開いている窓の一覧も AppKit がここに足す
        let window = try menu("ウインドウ")
        let minimize = try #require(find(window, #selector(NSWindow.performMiniaturize(_:))))
        #expect(minimize.keyEquivalent == "m" && minimize.keyEquivalentModifierMask == [.command])
        #expect(find(window, #selector(NSWindow.performZoom(_:))) != nil)
        #expect(find(window, #selector(NSApplication.arrangeInFront(_:))) != nil)
        #expect(find(window, #selector(NSWindow.performClose(_:))) == nil)
        #expect(app.windowsMenu === window)
    }

    /// 前面に窓が無いとき、フルスクリーンの項目は「フルスクリーンにする」のまま使えない
    @Test @MainActor func fullScreenItemNeedsAWindow() {
        let d = AppDelegate()
        let item = NSMenuItem(title: "x", action: #selector(AppDelegate.toggleFullScreenOfFrontWindow(_:)), keyEquivalent: "f")
        if NSApp.keyWindow == nil && NSApp.mainWindow == nil {
            #expect(!d.validateMenuItem(item))
            #expect(item.title == "フルスクリーンにする")
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ s: String, from start: String, length: Int = 1600) throws -> String {
        let r = try #require(s.range(of: start))
        return String(s[r.lowerBound...].prefix(length))
    }

    /// 窓を出す「前」に普通のアプリにする（出したあとで数えると、まだ窓が無いので Dock に出ないアプリのままになっていた）
    @Test func showBecomesRegularBeforeTheWindowAppears() throws {
        let s = try source("Sources/JellyfishAI/UI/ChatWindow.swift")
        let show = try body(s, from: "func show(near jelly: JellyController")
        let regular = try #require(show.range(of: "chatWindowVisibilityChanged(showing: true)"))
        let front = try #require(show.range(of: "makeKeyAndOrderFront"))
        let frontNoActivate = try #require(show.range(of: "orderFrontRegardless"))
        #expect(regular.lowerBound < front.lowerBound)
        #expect(regular.lowerBound < frontNoActivate.lowerBound)
        let manager = try source("Sources/JellyfishAI/App/JellyManager.swift")
        let policy = try body(manager, from: "func chatWindowVisibilityChanged(showing: Bool = false)", length: 600)
        #expect(policy.contains("showing ||"))
    }

    /// フル画面のチャットは、Esc・送信・クラゲを消したときに「画面から外すだけ」にしない（空のフル画面が残って戻れなくなる）
    @Test func fullScreenChatIsNeverJustOrderedOut() throws {
        let s = try source("Sources/JellyfishAI/UI/ChatWindow.swift")
        let close = try body(s, from: "func closeAndReturn()", length: 1200)
        let guardFS = try #require(close.range(of: "if isFullScreen"))
        let orderOut = try #require(close.range(of: "window.orderOut(nil)"))
        #expect(guardFS.lowerBound < orderOut.lowerBound)
        let dismiss = try body(s, from: "func dismiss()", length: 300)
        #expect(dismiss.contains("if !isFullScreen { window.orderOut(nil) }"))
        // クラゲを消したとき・言語を変えたときは dismiss() で閉じる
        let manager = try source("Sources/JellyfishAI/App/JellyManager.swift")
        #expect(!manager.contains("chat.window.orderOut(nil)"))
    }
}
