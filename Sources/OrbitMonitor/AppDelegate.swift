import AppKit
import MonitorCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    /// 界面语言。与 Strings/Localization 共用同一实例，切换后所有窗口同步刷新。
    private let localization = Localization.shared
    private let updates = UpdateChecker()
    /// 自动更新的下载与安装编排。与 updates（纯检查）分开，职责不同。
    private let updateFlow = UpdateFlow()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 34)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    /// 设置窗口当前显示的分区。菜单里的「检查更新」需要切到 .update。
    private var settingsSection: SettingsSection = .general
    private var uninstallerWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var animationTimer: Timer?
    /// 自动更新的后台编排任务；退出前要取消。
    private var autoUpdateTask: Task<Void, Never>?
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
            }).localized(localization)
        )
        panelController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panelController
        // 启动时直接走 updateIcon：它会根据「是否暂停」决定显示动物还是暂停图标，
        // 不能在这里硬写动物帧，否则若上次退出时处于暂停状态，重启后会错误地显示动画。
        updateIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = localization.t(.tooltipStatus)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        store.start()
        startAutoUpdate()
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
            window.title = localization.t(.previewTitle)
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
        autoUpdateTask?.cancel()
        store.stop()
        animationTimer?.invalidate()
    }

    // Closing the uninstaller (or settings) window must not terminate the menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 自动更新编排：按设置决定「检查 → 下载 → 安装」走到哪一步。
    ///
    /// 三步是递进的，后一步依赖前一步的开关：
    /// 关掉自动检查就不会自动下载，关掉自动下载就不会自动安装。
    /// 自动安装默认关闭——它会让应用自行退出重启，属于侵入性操作。
    private func startAutoUpdate() {
        guard store.autoCheckUpdates else { return }
        updates.startAutomaticChecks()

        // 检查完成后再决定要不要自动下载：轮询 updates.state 的变化。
        autoUpdateTask = Task { [weak self] in
            guard let self else { return }
            // 等这一轮检查出结果（最多 30 秒，避免网络挂住时任务永久存活）。
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if case .available = self.updates.state { break }
                if case .failed = self.updates.state { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            guard self.store.autoDownloadUpdates,
                  case let .available(release, download) = self.updates.state,
                  !self.updateFlow.isBusy else { return }
            self.startBackgroundInstall(release: release, download: download)
        }
    }

    /// 后台自动下载（并按设置决定是否自动重启安装）。
    private func startBackgroundInstall(release: UpdateRelease, download: UpdateDownload) {
        updateFlow.start(
            release: release,
            download: download,
            targetApp: Bundle.main.bundleURL,
            onReadyToRestart: { [weak self] prepared in
                guard let self else { return }
                guard self.store.autoInstallUpdates else { return }
                self.showRestartNoticeThenQuit(prepared)
            },
            onFailure: { [weak self] _ in
                // 后台自动更新失败不弹窗打扰：用户下次打开设置页能看到原因。
                self?.updateFlow.reset()
            }
        )
    }

    /// 自动安装前给一个短提示，然后退出并重启。
    private func showRestartNoticeThenQuit(_ prepared: UpdateInstaller.Prepared) {
        let alert = NSAlert()
        alert.messageText = localization.t(.updateRestarting)
        alert.informativeText = localization.t(.updateSettingsAutoInstallHint)
        alert.addButton(withTitle: localization.t(.ok))
        alert.runModal()

        guard UpdateInstaller.launch(prepared) else {
            updateFlow.markInstallLaunchFailed()
            return
        }
        NSApp.terminate(nil)
    }

    private func updateIcon() {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = ProcessInfo.processInfo.systemUptime
        if store.animationPaused || reducedMotion {
            lastFrame = now
            animationFrame = 0
            // 暂停时显示 Logo 图标，而不是把动物冻在第 0 帧——
            // 后者看起来像卡住的动画，分不清「暂停」和「不动」。
            // 每次都设置是幂等的；用 identity 比较避免无谓重绘。
            let pausedImage = StatusAnimal.paused(animal: store.animal)
            if statusItem.button?.image !== pausedImage {
                statusItem.button?.image = pausedImage
            }
            return
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
        let open = NSMenuItem(title: localization.t(.menuOpenPanel), action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let pause = NSMenuItem(title: localization.t(.menuPauseAnimation), action: #selector(toggleAnimation), keyEquivalent: "")
        pause.target = self
        pause.state = store.animationPaused ? .on : .off
        menu.addItem(pause)
        let animals = NSMenu()
        for animal in Animal.allCases {
            let item = NSMenuItem(title: animal.displayName, action: #selector(selectAnimal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = animal.rawValue
            item.state = store.animal == animal ? .on : .off
            animals.addItem(item)
        }
        let choice = NSMenuItem(title: localization.t(.menuChangeAnimal), action: nil, keyEquivalent: "")
        choice.submenu = animals
        menu.addItem(choice)
        menu.addItem(.separator())
        let login = NSMenuItem(title: localization.t(.menuLoginAtStartup), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = store.launchAtLogin ? .on : .off
        menu.addItem(login)
        let check = NSMenuItem(title: updates.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let settings = NSMenuItem(title: localization.t(.menuSettings), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: localization.t(.menuQuit), action: #selector(quitApp), keyEquivalent: "")
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
        // 同样走 updateIcon：暂停状态下换动物，应继续显示暂停图标，
        // 而不是把暂停状态悄悄「解开」成一张静止的动物图。
        updateIcon()
    }

    @objc private func toggleLogin() {
        do { try store.setLaunchAtLogin(!store.launchAtLogin) }
        catch { showError(localization.t(.cannotChangeLogin, error.localizedDescription)) }
    }

    /// 菜单/面板里的「设置」：总是回到「通用」。
    ///
    /// 这里刻意**不**保留上次的分区：如果上次是从「检查更新」跳进来的，
    /// 窗口停在「更新」页；用户随后点「设置」却还停在更新页，会以为按钮没生效。
    /// 每个入口对应一个确定的分区，语义才可预期。
    @objc private func openSettings() {
        showSettings(section: .general)
    }

    /// 打开设置窗口并切到指定分区。
    private func showSettings(section: SettingsSection) {
        settingsSection = section
        openSettingsWindow()?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettingsWindow() {
        openSettingsWindow()?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单里的「检查更新」：跳到设置的「更新」分区，再强制检查一次（绕过节流）。
    ///
    /// 必须切到 .update 而不是单纯打开窗口：设置页默认停在「通用」，
    /// 用户点「检查更新」却看到动物和刷新频率，会以为没反应。
    @objc private func checkForUpdates() {
        showSettings(section: .update)
        Task { await updates.check(force: true) }
    }

    @discardableResult
    private func openSettingsWindow() -> NSWindow? {
        if settingsWindow == nil {
            // 高度按内容自适应：Form 的固有高度会随分区数量与说明文字变化，
            // 写死窗口高度会在内容变多时立刻出现滚动条。这里用 NSHostingController
            // 上报首选尺寸，窗口直接取「内容高度」，默认打开时正好没有滚动条。
            let controller = NSHostingController(
                rootView: SettingsPanel(store: store, updates: updates,
                                        localization: localization, flow: updateFlow,
                                        selection: Binding(
                                            get: { [weak self] in self?.settingsSection ?? .general },
                                            set: { [weak self] in self?.settingsSection = $0 }
                                        ))
                    .localized(localization)
            )
            controller.sizingOptions = [.preferredContentSize]
            let content = controller.preferredContentSize
            let contentHeight = content.height > 0 ? content.height : 620

            // 初始高度取内容高度，但不超过屏幕可用高度再留出标题栏与边距的余量，
            // 否则在小屏笔记本上窗口会伸出屏幕外。超出上限时让内容滚动。
            let visible = (NSScreen.main?.visibleFrame.height ?? 900) - 80
            let height = min(contentHeight, max(visible, 520))

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            // 最小高度取「内容高度」与屏幕可用高度的较小值：内容不溢出时正好没有滚动条，
            // 屏幕太矮时也允许用户把窗口缩小到能放下为止。
            window.minSize = NSSize(width: 380, height: min(contentHeight, max(visible, 520)))
            window.title = localization.t(.settingsTitle)
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
            window.title = localization.t(.uninstallerWindowTitle)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 780, height: 560)
            window.contentView = NSHostingView(rootView: UninstallerPanel().localized(localization))
            uninstallerWindow = window
            window.center()
        }
        uninstallerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = localization.t(.operationFailed)
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
