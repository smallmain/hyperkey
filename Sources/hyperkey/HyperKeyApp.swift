import AppKit
import ApplicationServices
import Foundation

@main
struct HyperKeyApp {
    static func main() {
        // Handle --uninstall flag
        if CommandLine.arguments.contains("--uninstall") {
            HIDMapping.clearMapping()
            fputs("hyperkey: CapsLock mapping cleared.\n", stderr)
            return
        }

        // Handle --version flag
        if CommandLine.arguments.contains("--version") {
            print("hyperkey \(Constants.version)")
            return
        }

        // 1. Check for already-running instance
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Constants.bundleID)
        if runningApps.count > 1 {
            fputs("hyperkey: already running.\n", stderr)
            return
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == "hyperkey" && $0.processIdentifier != selfPID
        }
        if !others.isEmpty {
            fputs("hyperkey: already running.\n", stderr)
            return
        }

        // 2. Set up signal handlers for clean shutdown
        signal(SIGINT) { _ in
            HIDMapping.clearMapping()
            fputs("\nhyperkey: stopped, CapsLock mapping cleared.\n", stderr)
            exit(0)
        }
        signal(SIGTERM) { _ in
            HIDMapping.clearMapping()
            fputs("hyperkey: stopped, CapsLock mapping cleared.\n", stderr)
            exit(0)
        }

        // 3. Set up NSApplication with menu bar item
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate

        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var updateMenuItem: NSMenuItem!
    private var installUpdateItem: NSMenuItem!
    private var checkForUpdatesItem: NSMenuItem!
    private var warningMenuItem: NSMenuItem!
    private var keyboardsMenuItem: NSMenuItem!
    private var updateInfo: UpdateChecker.UpdateInfo?
    private var hidMappingOK = true
    private var servicesStarted = false
    private var isInstallingUpdate = false

    private let escapeKey = "escapeOnTap"
    private let hyperNavigationKey = "hyperNavigationEnabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedEscape = UserDefaults.standard.bool(forKey: escapeKey)
        let savedHyperNavigation = UserDefaults.standard.bool(forKey: hyperNavigationKey)
        escapeOnTap = savedEscape
        hyperNavigationEnabled = savedHyperNavigation

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.toolTip = L10n.appName
            if let image = NSImage(
                systemSymbolName: "capslock.fill",
                accessibilityDescription: L10n.appName
            ) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = L10n.tr("status_item.fallback_title", default: "HK")
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        // Version
        let statusMenuItem = NSMenuItem(
            title: L10n.tr("menu.version", default: "%@ v%@", L10n.appName, Constants.version),
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Update available (hidden until detected)
        updateMenuItem = NSMenuItem(
            title: L10n.tr("menu.update_available", default: "Update available"),
            action: #selector(openUpdate(_:)),
            keyEquivalent: ""
        )
        updateMenuItem.target = self
        updateMenuItem.isHidden = true
        menu.addItem(updateMenuItem)

        installUpdateItem = NSMenuItem(
            title: L10n.tr("menu.update_now", default: "Update Now"),
            action: #selector(installUpdate(_:)),
            keyEquivalent: ""
        )
        installUpdateItem.target = self
        installUpdateItem.isHidden = true
        menu.addItem(installUpdateItem)

        // Check for Updates
        checkForUpdatesItem = NSMenuItem(
            title: L10n.tr("menu.check_for_updates", default: "Check for Updates"),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        // Warning (hidden unless something is wrong)
        warningMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningMenuItem.isHidden = true
        menu.addItem(warningMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Keyboards submenu
        keyboardsMenuItem = NSMenuItem(
            title: L10n.tr("menu.keyboards", default: "Keyboards"),
            action: nil,
            keyEquivalent: ""
        )
        let keyboardsSubmenu = NSMenu()
        keyboardsMenuItem.submenu = keyboardsSubmenu
        menu.addItem(keyboardsMenuItem)

        menu.addItem(NSMenuItem.separator())

        // CapsLock -> Escape toggle
        let escapeItem = NSMenuItem(
            title: L10n.tr("menu.escape_on_tap", default: "CapsLock alone → Escape"),
            action: #selector(toggleEscape(_:)),
            keyEquivalent: ""
        )
        escapeItem.target = self
        escapeItem.state = savedEscape ? .on : .off
        menu.addItem(escapeItem)

        let hyperNavigationItem = NSMenuItem(
            title: L10n.tr("menu.hyper_navigation", default: "Hyper + HJKL → Arrows"),
            action: #selector(toggleHyperNavigation(_:)),
            keyEquivalent: ""
        )
        hyperNavigationItem.target = self
        hyperNavigationItem.state = savedHyperNavigation ? .on : .off
        menu.addItem(hyperNavigationItem)

        // Launch at Login toggle
        let launchItem = NSMenuItem(
            title: L10n.tr("menu.launch_at_login", default: "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAgentInstalled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: L10n.tr("menu.quit", default: "Quit %@", L10n.appName),
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Check for updates (uses 24h cache)
        Task { await performUpdateCheck() }

        warningMenuItem.title = L10n.tr(
            "warning.waiting_accessibility",
            default: "Waiting for Accessibility permission..."
        )
        warningMenuItem.isHidden = AXIsProcessTrusted()

        DispatchQueue.main.async { [weak self] in
            self?.startKeyboardServicesWhenReady()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HIDMapping.clearMapping()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Check accessibility on every menu open
        if !AXIsProcessTrusted() {
            warningMenuItem.title = servicesStarted
                ? L10n.tr(
                    "warning.accessibility_revoked",
                    default: "Warning: Accessibility permission revoked"
                )
                : L10n.tr(
                    "warning.waiting_accessibility",
                    default: "Waiting for Accessibility permission..."
                )
            warningMenuItem.isHidden = false
        } else if hidMappingOK {
            warningMenuItem.isHidden = true
        }

        // Refresh keyboards submenu
        if let submenu = keyboardsMenuItem.submenu {
            submenu.removeAllItems()
            let devices = KeyboardMonitor.connectedDevices
            if devices.isEmpty {
                let item = NSMenuItem(
                    title: L10n.tr("menu.no_keyboards", default: "No keyboards detected"),
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                submenu.addItem(item)
            } else {
                for device in devices {
                    let item = NSMenuItem(
                        title: L10n.tr(
                            "keyboard.item",
                            default: "%@ (%@)",
                            device.name,
                            device.status.localizedTitle
                        ),
                        action: nil,
                        keyEquivalent: ""
                    )
                    item.isEnabled = false
                    submenu.addItem(item)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleEscape(_ sender: NSMenuItem) {
        let newValue = sender.state != .on
        escapeOnTap = newValue
        sender.state = newValue ? .on : .off
        UserDefaults.standard.set(newValue, forKey: escapeKey)
    }

    @objc private func toggleHyperNavigation(_ sender: NSMenuItem) {
        let newValue = sender.state != .on
        hyperNavigationEnabled = newValue
        sender.state = newValue ? .on : .off
        UserDefaults.standard.set(newValue, forKey: hyperNavigationKey)
    }

    @objc private func openUpdate(_ sender: NSMenuItem) {
        if let urlString = updateInfo?.releasePageURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func installUpdate(_ sender: NSMenuItem) {
        guard !isInstallingUpdate, let update = updateInfo else { return }
        guard update.downloadURL != nil else {
            openUpdate(sender)
            return
        }

        isInstallingUpdate = true
        installUpdateItem.title = L10n.tr(
            "menu.downloading_update",
            default: "Downloading Update..."
        )
        installUpdateItem.isEnabled = false
        updateMenuItem.isEnabled = false
        checkForUpdatesItem.isEnabled = false

        Task { [weak self] in
            guard let self else { return }
            do {
                try await AppUpdater.install(update: update)
            } catch {
                self.handleUpdateFailure(error, update: update)
            }
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        sender.title = L10n.tr("menu.checking_for_updates", default: "Checking...")
        sender.isEnabled = false
        Task {
            await performUpdateCheck(force: true)
            sender.title = L10n.tr("menu.check_for_updates", default: "Check for Updates")
            sender.isEnabled = true
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let plistName = "\(Constants.bundleID).plist"
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent(plistName)
        let uid = getuid()

        if sender.state == .on {
            // Unload
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(uid)/\(plistName)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(at: plistPath)
            sender.state = .off
        } else {
            // Install and load
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            let execPath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(Constants.bundleID)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                    <key>Crashed</key>
                    <true/>
                </dict>
                <key>ProcessType</key>
                <string>Interactive</string>
                <key>StandardOutPath</key>
                <string>/tmp/hyperkey.out.log</string>
                <key>StandardErrorPath</key>
                <string>/tmp/hyperkey.err.log</string>
                <key>LimitLoadToSessionType</key>
                <string>Aqua</string>
            </dict>
            </plist>
            """

            do {
                try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            } catch {
                fputs("hyperkey: failed to write LaunchAgent plist: \(error)\n", stderr)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(uid)", plistPath.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    sender.state = .on
                } else {
                    fputs("hyperkey: launchctl bootstrap failed (status \(process.terminationStatus))\n", stderr)
                }
            } catch {
                fputs("hyperkey: failed to run launchctl: \(error)\n", stderr)
            }
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        HIDMapping.clearMapping()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func performUpdateCheck(force: Bool = false) async {
        do {
            if let update = try await UpdateChecker.check(force: force) {
                updateInfo = update
                updateMenuItem.title = L10n.tr(
                    "menu.update_available_version",
                    default: "Update available: v%@",
                    update.version
                )
                updateMenuItem.isHidden = false
                updateMenuItem.isEnabled = !isInstallingUpdate
                installUpdateItem.title = isInstallingUpdate
                    ? L10n.tr("menu.downloading_update", default: "Downloading Update...")
                    : L10n.tr("menu.update_now", default: "Update Now")
                installUpdateItem.isHidden = update.downloadURL == nil
                installUpdateItem.isEnabled = !isInstallingUpdate && update.downloadURL != nil
            } else if force {
                updateInfo = nil
                updateMenuItem.title = L10n.tr("menu.up_to_date", default: "Up to date")
                updateMenuItem.isHidden = false
                updateMenuItem.isEnabled = false
                installUpdateItem.isHidden = true
                // Hide "up to date" after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.updateInfo == nil {
                        self?.updateMenuItem.isHidden = true
                    }
                }
            }
        } catch {
            fputs("hyperkey: update check failed: \(error)\n", stderr)
            if force {
                showAlert(
                    title: L10n.tr(
                        "alert.update_check_failed.title",
                        default: "Unable to Check for Updates"
                    ),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func isLaunchAgentInstalled() -> Bool {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Constants.bundleID).plist")
        return FileManager.default.fileExists(atPath: plistPath.path)
    }

    private func startKeyboardServicesWhenReady() {
        guard !servicesStarted else { return }
        Accessibility.waitForPermission { [weak self] in
            self?.startKeyboardServices()
        }
    }

    private func startKeyboardServices() {
        guard !servicesStarted else { return }
        hidMappingOK = HIDMapping.applyCapsLockToF18()
        if !hidMappingOK {
            warningMenuItem.title = L10n.tr(
                "warning.hid_mapping_failed",
                default: "Warning: HID mapping failed"
            )
            warningMenuItem.isHidden = false
        } else {
            warningMenuItem.isHidden = true
        }

        KeyboardMonitor.start()
        EventTap.start()
        servicesStarted = true
    }

    private func handleUpdateFailure(_ error: Error, update: UpdateChecker.UpdateInfo) {
        isInstallingUpdate = false
        updateInfo = update
        updateMenuItem.isEnabled = true
        installUpdateItem.title = L10n.tr("menu.update_now", default: "Update Now")
        installUpdateItem.isHidden = update.downloadURL == nil
        installUpdateItem.isEnabled = update.downloadURL != nil
        checkForUpdatesItem.isEnabled = true

        showAlert(
            title: L10n.tr("alert.update_failed.title", default: "Update Failed"),
            message: error.localizedDescription
        )
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.tr("alert.ok", default: "OK"))
        alert.runModal()
    }
}
