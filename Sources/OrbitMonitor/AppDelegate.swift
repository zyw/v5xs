import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    private let updates = UpdateChecker()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 34)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var uninstallerWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var lastFrame: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popover.behavior = .transient
        let panelController = NSHostingController(
            rootView: MonitorPanel(store: store, updates: updates, onOpenSettings: { [weak self] in
                self?.openSettings()
            }, onOpenUninstaller: { [weak self] in
                self?.openUninstaller()
            })
        )
        panelController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panelController
        statusItem.button?.image = StatusAnimal.image(animal: store.animal, frame: 0)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "CPU 越忙，动物跑得越快；右键可更换形象"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        store.start()
        updates.startAutomaticChecks()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        lastFrame = ProcessInfo.processInfo.systemUptime
        if ProcessInfo.processInfo.arguments.contains("--preview-window") {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 590),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "v5xs 预览"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: MonitorPanel(store: store, updates: updates, onOpenSettings: { [weak self] in
                    self?.openSettings()
                }, onOpenUninstaller: { [weak self] in
                    self?.openUninstaller()
                })
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
        // 调试入口：直接打开设置窗口，便于在无辅助功能权限时检查「更新」分区。
        if ProcessInfo.processInfo.arguments.contains("--settings-window") {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        animationTimer?.invalidate()
    }

    // Closing the uninstaller (or settings) window must not terminate the menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func updateIcon() {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = ProcessInfo.processInfo.systemUptime
        if store.animationPaused || reducedMotion {
            lastFrame = now
            if animationFrame == 0 { return }
            animationFrame = 0
        } else {
            let interval = store.pace.frameInterval
            let elapsed = now - lastFrame
            guard elapsed >= interval else { return }
            let steps = Int(elapsed / interval)
            animationFrame += steps
            lastFrame = now - elapsed.truncatingRemainder(dividingBy: interval)
        }
        statusItem.button?.image = StatusAnimal.image(animal: store.animal, frame: animationFrame)
    }

    @objc private func statusClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showShortcutMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showShortcutMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开监控面板", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let pause = NSMenuItem(title: "暂停图标动画", action: #selector(toggleAnimation), keyEquivalent: "")
        pause.target = self
        pause.state = store.animationPaused ? .on : .off
        menu.addItem(pause)
        let animals = NSMenu()
        for animal in Animal.allCases {
            let item = NSMenuItem(title: animal.rawValue, action: #selector(selectAnimal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = animal.rawValue
            item.state = store.animal == animal ? .on : .off
            animals.addItem(item)
        }
        let choice = NSMenuItem(title: "更换形象", action: nil, keyEquivalent: "")
        choice.submenu = animals
        menu.addItem(choice)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = store.launchAtLogin ? .on : .off
        menu.addItem(login)
        let check = NSMenuItem(title: updates.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func toggleAnimation() { store.animationPaused.toggle(); updateIcon() }
    @objc private func selectAnimal(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let animal = Animal(rawValue: name) else { return }
        store.animal = animal
        statusItem.button?.image = StatusAnimal.image(animal: animal, frame: 0)
    }

    @objc private func toggleLogin() {
        do { try store.setLaunchAtLogin(!store.launchAtLogin) }
        catch { showError("无法更改登录启动设置：\(error.localizedDescription)") }
    }

    @objc private func openSettings() {
        openSettingsWindow()?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单里的「检查更新」：先打开设置窗口展示状态，再强制检查一次（绕过节流）。
    @objc private func checkForUpdates() {
        openSettings()
        Task { await updates.check(force: true) }
    }

    @discardableResult
    private func openSettingsWindow() -> NSWindow? {
        if settingsWindow == nil {
            // 高度按内容自适应：Form 的固有高度会随分区数量与说明文字变化，
            // 写死窗口高度会在内容变多时立刻出现滚动条。这里用 NSHostingController
            // 上报首选尺寸，窗口直接取「内容高度」，默认打开时正好没有滚动条。
            let controller = NSHostingController(rootView: SettingsPanel(store: store, updates: updates))
            controller.sizingOptions = [.preferredContentSize]
            let preferred = controller.preferredContentSize
            let height = preferred.height > 0 ? preferred.height : 620

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 380, height: height)
            window.title = "v5xs 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = controller
            settingsWindow = window
        }
        return settingsWindow
    }

    private func openUninstaller() {
        if uninstallerWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "v5xs · 软件卸载"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 780, height: 560)
            window.contentView = NSHostingView(rootView: UninstallerPanel())
            uninstallerWindow = window
            window.center()
        }
        uninstallerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = message
        alert.runModal()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === uninstallerWindow { uninstallerWindow = nil }
        else if window === settingsWindow { settingsWindow = nil }
        else if window === previewWindow { previewWindow = nil }
    }
}

@main
enum OrbitMonitorApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
