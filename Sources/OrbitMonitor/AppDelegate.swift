import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 34)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var lastFrame: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popover.behavior = .transient
        let panelController = NSHostingController(
            rootView: MonitorPanel(store: store, onOpenSettings: { [weak self] in
                self?.openSettings()
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
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
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
            window.contentView = NSHostingView(
                rootView: MonitorPanel(store: store, onOpenSettings: { [weak self] in
                    self?.openSettings()
                })
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        animationTimer?.invalidate()
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
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 370, height: 250),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "v5xs 设置"
            window.contentView = NSHostingView(rootView: SettingsPanel(store: store))
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
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

@main
enum OrbitMonitorApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
