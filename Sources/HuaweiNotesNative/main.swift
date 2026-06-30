import AppKit
import HuaweiNotesCore
import Network
import WebKit

enum AppConfig {
    static let bundleIdentifier = "com.codex.huaweinotes"
    static let appDisplayName = "华为备忘录"
    static let fallbackAppVersion = "1.0.0"
    static let defaultHomeURL = "https://cloud.huawei.com/"
    static let defaultNotesURL = "https://cloud.huawei.com/home#/notepad/note/allNote"
    static let defaultKeepAliveSeconds: TimeInterval = 60
    static let minimumReloadGap: TimeInterval = 15
    static let reconnectDelay: TimeInterval = 1.5

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackAppVersion
    }

    static var homeURL: URL {
        let rawValue = UserDefaults.standard.string(forKey: "HomeURL") ?? defaultHomeURL
        return URL(string: rawValue) ?? URL(string: defaultHomeURL)!
    }

    static var notesURL: URL {
        let rawValue = UserDefaults.standard.string(forKey: "StartURL") ?? defaultNotesURL
        return URL(string: rawValue) ?? URL(string: defaultNotesURL)!
    }

    static var keepAliveSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "KeepAliveSeconds")
        return value >= 60 ? value : defaultKeepAliveSeconds
    }

    static var reloadEveryProbe: Bool {
        guard UserDefaults.standard.object(forKey: "ReloadOnEveryProbe") != nil else {
            return false
        }
        return UserDefaults.standard.bool(forKey: "ReloadOnEveryProbe")
    }

    static var restoreCookieVaultOnLaunch: Bool {
        guard UserDefaults.standard.object(forKey: "RestoreCookieVaultOnLaunch") != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: "RestoreCookieVaultOnLaunch")
    }
}

enum StatusStyle {
    case neutral
    case working
    case success
    case warning
    case error

    var color: NSColor {
        switch self {
        case .neutral:
            return .secondaryLabelColor
        case .working:
            return .systemBlue
        case .success:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .error:
            return .systemRed
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let browserSession = BrowserSession()
    private var controller: NotesWindowController?
    private var isWaitingForCookieSnapshotBeforeQuit = false
    private var didRunShutdownCleanup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SessionDiagnostics.shared.log("app_start", fields: [
            "bundlePath": Bundle.main.bundlePath,
            "version": AppConfig.appVersion,
            "pid": "\(ProcessInfo.processInfo.processIdentifier)"
        ])
        controller = NotesWindowController(browserSession: browserSession)
        configureMainMenu()
        controller?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        performShutdownCleanup()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForCookieSnapshotBeforeQuit else {
            return .terminateLater
        }

        isWaitingForCookieSnapshotBeforeQuit = true
        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            await self.controller?.persistCookiesBeforeTermination()
            self.performShutdownCleanup()
            self.isWaitingForCookieSnapshotBeforeQuit = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        controller?.show()
        return true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: AppConfig.appDisplayName)
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于\(AppConfig.appDisplayName)（v\(AppConfig.appVersion)）", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let clearLoginItem = NSMenuItem(title: "清除登录数据…", action: #selector(NotesWindowController.clearLoginData), keyEquivalent: "")
        clearLoginItem.target = controller
        appMenu.addItem(clearLoginItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: "隐藏\(AppConfig.appDisplayName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出\(AppConfig.appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu

        let closeItem = NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = nil
        fileMenu.addItem(closeItem)
        fileMenu.addItem(.separator())

        let openInBrowserItem = NSMenuItem(title: "在浏览器中打开", action: #selector(NotesWindowController.openCurrentPageInBrowser), keyEquivalent: "o")
        openInBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        openInBrowserItem.target = controller
        fileMenu.addItem(openInBrowserItem)

        let printItem = NSMenuItem(title: "打印…", action: #selector(NotesWindowController.printCurrentPage), keyEquivalent: "p")
        printItem.keyEquivalentModifierMask = [.command]
        printItem.target = controller
        fileMenu.addItem(printItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        let undoItem = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.target = nil
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.target = nil
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.target = nil
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.target = nil
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.target = nil
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = nil
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())

        let findItem = NSMenuItem(title: "查找…", action: #selector(NotesWindowController.showFindPanel), keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = [.command]
        findItem.target = controller
        editMenu.addItem(findItem)

        let findNextItem = NSMenuItem(title: "查找下一个", action: #selector(NotesWindowController.findNext), keyEquivalent: "g")
        findNextItem.keyEquivalentModifierMask = [.command]
        findNextItem.target = controller
        editMenu.addItem(findNextItem)

        let findPreviousItem = NSMenuItem(title: "查找上一个", action: #selector(NotesWindowController.findPrevious), keyEquivalent: "G")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.target = controller
        editMenu.addItem(findPreviousItem)

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu

        let zoomInItem = NSMenuItem(title: "放大", action: #selector(NotesWindowController.zoomIn), keyEquivalent: "+")
        zoomInItem.keyEquivalentModifierMask = [.command]
        zoomInItem.target = controller
        viewMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "缩小", action: #selector(NotesWindowController.zoomOut), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = [.command]
        zoomOutItem.target = controller
        viewMenu.addItem(zoomOutItem)

        let actualSizeItem = NSMenuItem(title: "实际大小", action: #selector(NotesWindowController.resetZoom), keyEquivalent: "0")
        actualSizeItem.keyEquivalentModifierMask = [.command]
        actualSizeItem.target = controller
        viewMenu.addItem(actualSizeItem)

        let actionsMenuItem = NSMenuItem()
        mainMenu.addItem(actionsMenuItem)
        let actionsMenu = NSMenu(title: "操作")
        actionsMenuItem.submenu = actionsMenu

        let homeItem = NSMenuItem(title: "回到主页", action: #selector(NotesWindowController.loadHome), keyEquivalent: "H")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        homeItem.target = controller
        actionsMenu.addItem(homeItem)

        let notesItem = NSMenuItem(title: "进入备忘录", action: #selector(NotesWindowController.openNotesArea), keyEquivalent: "1")
        notesItem.keyEquivalentModifierMask = [.command]
        notesItem.target = controller
        actionsMenu.addItem(notesItem)

        let reloadItem = NSMenuItem(title: "刷新", action: #selector(NotesWindowController.reloadCurrentPage), keyEquivalent: "r")
        reloadItem.keyEquivalentModifierMask = [.command]
        reloadItem.target = controller
        actionsMenu.addItem(reloadItem)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu

        let minimizeItem = NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimizeItem.target = nil
        windowMenu.addItem(minimizeItem)

        let zoomItem = NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        zoomItem.target = nil
        windowMenu.addItem(zoomItem)

        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func performShutdownCleanup() {
        guard !didRunShutdownCleanup else { return }
        didRunShutdownCleanup = true
        controller?.tearDown()
        browserSession.invalidate()
    }
}

extension NSToolbarItem.Identifier {
    static let huaweiBack = NSToolbarItem.Identifier("com.codex.huaweinotes.toolbar.back")
    static let huaweiForward = NSToolbarItem.Identifier("com.codex.huaweinotes.toolbar.forward")
    static let huaweiReloadStop = NSToolbarItem.Identifier("com.codex.huaweinotes.toolbar.reload-stop")
}

@MainActor
final class NotesWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate {
    private static let windowAutosaveName = "HuaweiNotesMainWindow"
    private static let pageZoomDefaultsKey = "PageZoom"
    private static let webContentTopInset: CGFloat = 28

    private let browserSession: BrowserSession
    private let heartbeatClient = HeartbeatClient()
    private let diagnostics = SessionDiagnostics.shared
    private let window: NSWindow
    private let rootView = NSView()
    private let contentBackgroundView = NSView()
    private let webView: WKWebView
    private let launchPlaceholder = NSVisualEffectView()
    private let launchSpinner = NSProgressIndicator()
    private let launchIconView = NSImageView()
    private let launchLabel = NSTextField(labelWithString: "正在打开华为备忘录")
    private let statusBanner = NSVisualEffectView()
    private let statusBannerLabel = NSTextField(labelWithString: "")

    private var keepAliveTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "HuaweiNotesNative.PathMonitor")
    private var lastNetworkSatisfied: Bool?
    private var lastReloadAt = Date.distantPast
    private var lastInactiveAt: Date?
    private var probeInFlight = false
    private var lifetimeActivity: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var lastNotesNavigationAt = Date.distantPast
    private var automaticNotesJumpAttempts = 0
    private var lastFindString = ""
    private var popupControllers: [PopupWindowController] = []
    private var toolbarItemsByIdentifier: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var initialLoadStarted = false
    private var hasHiddenLaunchPlaceholder = false
    private var wasAuthenticated = false
    private var loadingProbeCount = 0
    private var lastLoadingKeepAliveAt = Date.distantPast
    private var heartbeatInFlight = false
    private var loginRecoveryInProgress = false
    private var loginRecoveryAttempted = false
    private var statusBannerHideWorkItem: DispatchWorkItem?

    init(browserSession: BrowserSession) {
        self.browserSession = browserSession
        let configuration = browserSession.makeConfiguration()

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = Self.webBackgroundColor

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.pageZoom = Self.savedPageZoom()

        configureWindow()
        configureLayout()
        installObservers()
        installAppearanceObserver()
        beginLifetimeActivity()
        startNetworkMonitor()
        startKeepAliveLoop()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !initialLoadStarted {
            initialLoadStarted = true
            restoreSessionAndOpenNotes()
        }
    }

    func tearDown() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        pathMonitor.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
        if let lifetimeActivity {
            ProcessInfo.processInfo.endActivity(lifetimeActivity)
            self.lifetimeActivity = nil
        }
    }

    private func configureWindow() {
        window.title = AppConfig.appDisplayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        if #available(macOS 15.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Self.webBackgroundColor
        window.isOpaque = true
        window.minSize = NSSize(width: 980, height: 640)

        let autosaveKey = "NSWindow Frame \(Self.windowAutosaveName)"
        let hasSavedFrame = UserDefaults.standard.string(forKey: autosaveKey) != nil
        window.setFrameAutosaveName(Self.windowAutosaveName)
        if !hasSavedFrame {
            window.center()
        }
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "com.codex.huaweinotes.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
    }

    private func makeToolbarItem(
        identifier: NSToolbarItem.Identifier,
        symbolName: String,
        label: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = false
        item.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        toolbarItemsByIdentifier[identifier] = item
        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .huaweiBack,
            .huaweiForward,
            .huaweiReloadStop,
            .flexibleSpace
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .huaweiBack:
            return makeToolbarItem(
                identifier: itemIdentifier,
                symbolName: "chevron.left",
                label: "后退",
                action: #selector(goBack)
            )
        case .huaweiForward:
            return makeToolbarItem(
                identifier: itemIdentifier,
                symbolName: "chevron.right",
                label: "前进",
                action: #selector(goForward)
            )
        case .huaweiReloadStop:
            return makeToolbarItem(
                identifier: itemIdentifier,
                symbolName: "arrow.clockwise",
                label: "刷新",
                action: #selector(reloadOrStopLoading)
            )
        default:
            return nil
        }
    }

    private func configureLayout() {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = Self.webBackgroundColor.cgColor
        window.contentView = rootView

        contentBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        contentBackgroundView.wantsLayer = true
        rootView.addSubview(contentBackgroundView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(webView)

        configureLaunchPlaceholder()
        configureStatusBanner()

        NSLayoutConstraint.activate([
            contentBackgroundView.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentBackgroundView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentBackgroundView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentBackgroundView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            webView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.webContentTopInset),
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            launchPlaceholder.topAnchor.constraint(equalTo: rootView.topAnchor),
            launchPlaceholder.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            launchPlaceholder.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            launchPlaceholder.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func configureLaunchPlaceholder() {
        launchPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        launchPlaceholder.material = .contentBackground
        launchPlaceholder.blendingMode = .withinWindow
        launchPlaceholder.state = .followsWindowActiveState
        launchPlaceholder.wantsLayer = true
        launchPlaceholder.appearance = NSAppearance(named: .aqua)
        rootView.addSubview(launchPlaceholder)

        launchIconView.translatesAutoresizingMaskIntoConstraints = false
        launchIconView.image = NSApp.applicationIconImage
        launchIconView.imageScaling = .scaleProportionallyUpOrDown
        launchIconView.alphaValue = 0.94

        launchLabel.translatesAutoresizingMaskIntoConstraints = false
        launchLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        launchLabel.textColor = .secondaryLabelColor
        launchLabel.alignment = .center

        launchSpinner.translatesAutoresizingMaskIntoConstraints = false
        launchSpinner.controlSize = .small
        launchSpinner.style = .spinning
        launchSpinner.startAnimation(nil)

        let stack = NSStackView(views: [launchIconView, launchLabel, launchSpinner])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        launchPlaceholder.addSubview(stack)

        NSLayoutConstraint.activate([
            launchIconView.widthAnchor.constraint(equalToConstant: 72),
            launchIconView.heightAnchor.constraint(equalToConstant: 72),
            stack.centerXAnchor.constraint(equalTo: launchPlaceholder.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: launchPlaceholder.centerYAnchor, constant: -20)
        ])
    }

    private func configureStatusBanner() {
        statusBanner.translatesAutoresizingMaskIntoConstraints = false
        statusBanner.material = .popover
        statusBanner.blendingMode = .withinWindow
        statusBanner.state = .active
        statusBanner.appearance = NSAppearance(named: .aqua)
        statusBanner.wantsLayer = true
        statusBanner.alphaValue = 0
        statusBanner.isHidden = true
        statusBanner.layer?.cornerRadius = 9
        statusBanner.layer?.masksToBounds = true
        statusBanner.layer?.borderWidth = 1

        statusBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBannerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusBannerLabel.alignment = .center
        statusBannerLabel.lineBreakMode = .byTruncatingTail
        statusBanner.addSubview(statusBannerLabel)
        rootView.addSubview(statusBanner)

        NSLayoutConstraint.activate([
            statusBanner.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 5),
            statusBanner.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            statusBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            statusBanner.widthAnchor.constraint(lessThanOrEqualToConstant: 460),

            statusBannerLabel.topAnchor.constraint(equalTo: statusBanner.topAnchor, constant: 4),
            statusBannerLabel.leadingAnchor.constraint(equalTo: statusBanner.leadingAnchor, constant: 14),
            statusBannerLabel.trailingAnchor.constraint(equalTo: statusBanner.trailingAnchor, constant: -14),
            statusBannerLabel.bottomAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: -4)
        ])
    }

    private func installAppearanceObserver() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAppearance()
            }
        }

        refreshAppearance()
    }

    private func refreshAppearance() {
        rootView.layer?.backgroundColor = Self.webBackgroundColor.cgColor
        contentBackgroundView.layer?.backgroundColor = Self.webBackgroundColor.cgColor
        webView.underPageBackgroundColor = Self.webBackgroundColor
    }

    private static var webBackgroundColor: NSColor {
        NSColor(calibratedWhite: 1.0, alpha: 1.0)
    }

    private static func bannerBackgroundColor(for style: StatusStyle) -> NSColor {
        switch style {
        case .error:
            return NSColor.systemRed.withAlphaComponent(0.12)
        case .warning:
            return NSColor.systemOrange.withAlphaComponent(0.13)
        default:
            return NSColor.windowBackgroundColor.withAlphaComponent(0.88)
        }
    }

    private static func bannerBorderColor(for style: StatusStyle) -> NSColor {
        switch style {
        case .error:
            return NSColor.systemRed.withAlphaComponent(0.28)
        case .warning:
            return NSColor.systemOrange.withAlphaComponent(0.30)
        default:
            return NSColor.separatorColor.withAlphaComponent(0.4)
        }
    }

    private func installObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
    }

    private func beginLifetimeActivity() {
        lifetimeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep Huawei Notes responsive while preserving session state"
        )
    }

    private func startKeepAliveLoop() {
        keepAliveTimer?.invalidate()
        diagnostics.log("keepalive_loop_start", fields: [
            "interval": "\(AppConfig.keepAliveSeconds)"
        ])
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.keepAliveSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runKeepAliveProbe(reason: "timer")
            }
        }
        if let keepAliveTimer {
            RunLoop.main.add(keepAliveTimer, forMode: .common)
        }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            DispatchQueue.main.async {
                let isSatisfied = path.status == .satisfied
                let previous = self.lastNetworkSatisfied
                self.lastNetworkSatisfied = isSatisfied
                self.diagnostics.log("network_path", fields: [
                    "satisfied": "\(isSatisfied)",
                    "previous": previous.map { "\($0)" } ?? "nil"
                ])

                if isSatisfied, previous == false {
                    self.setStatus("网络已恢复，正在重新连接", style: .working, spinning: true)
                    self.recoverAfterResume(reason: "network-restored")
                } else if !isSatisfied {
                    self.setStatus("当前离线，网络恢复后会自动重连", style: .warning, spinning: false)
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    @objc
    private func handleAppDidBecomeActive() {
        guard initialLoadStarted else { return }
        diagnostics.log("app_active")
        guard let lastInactiveAt else {
            scheduleProbe(after: 0.8, reason: "launch")
            return
        }

        let idleTime = Date().timeIntervalSince(lastInactiveAt)
        if idleTime >= 20 {
            setStatus("正在恢复连接", style: .working, spinning: true)
            recoverAfterResume(reason: "app-active-\(Int(idleTime))s")
        }
    }

    @objc
    private func handleAppDidResignActive() {
        lastInactiveAt = Date()
        diagnostics.log("app_inactive")
        Task { @MainActor [weak self] in
            await self?.persistCookiesBeforeTermination()
        }
    }

    @objc
    private func handleWorkspaceDidWake() {
        diagnostics.log("workspace_wake")
        recoverAfterResume(reason: "workspace-wake")
    }

    @objc
    private func handleScreensDidWake() {
        diagnostics.log("screen_wake")
        recoverAfterResume(reason: "screen-wake")
    }

    @objc
    private func handleScreensDidSleep() {
        diagnostics.log("screen_sleep")
    }

    private func restoreSessionAndOpenNotes() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.browserSession.setCookiePersistencePaused(true)
            self.loadingProbeCount = 0
            self.lastLoadingKeepAliveAt = .distantPast
            self.loginRecoveryAttempted = false
            self.loginRecoveryInProgress = false
            self.diagnostics.log("session_open_start", fields: [
                "restoreVault": "\(AppConfig.restoreCookieVaultOnLaunch)"
            ])

            if AppConfig.restoreCookieVaultOnLaunch {
                self.setStatus("正在恢复备份登录态", style: .working, spinning: true)
                do {
                    let restoredCount = try await self.browserSession.restoreCookies()
                    self.diagnostics.log("cookie_restore_launch", fields: [
                        "count": "\(restoredCount)"
                    ])
                    if restoredCount > 0 {
                        self.setStatus("已恢复备份登录态", style: .success, spinning: false)
                    }
                } catch {
                    self.diagnostics.log("cookie_restore_launch_error", fields: [
                        "error": "\(error)"
                    ])
                    self.setStatus("备份登录态恢复失败", style: .warning, spinning: false)
                }
            } else {
                self.setStatus("正在打开备忘录", style: .working, spinning: true)
            }

            self.loadNotesURL()
        }
    }

    private func loadNotesURL() {
        let request = URLRequest(url: AppConfig.notesURL, cachePolicy: .useProtocolCachePolicy)
        loadingProbeCount = 0
        diagnostics.log("load_notes", fields: ["url": Self.sanitizedURLString(AppConfig.notesURL)])
        browserSession.setCookiePersistencePaused(true)
        setStatus("正在打开备忘录", style: .working, spinning: true)
        webView.load(request)
    }

    @objc
    fileprivate func loadHome() {
        let request = URLRequest(url: AppConfig.homeURL, cachePolicy: .useProtocolCachePolicy)
        loadingProbeCount = 0
        diagnostics.log("load_home", fields: ["url": Self.sanitizedURLString(AppConfig.homeURL)])
        browserSession.setCookiePersistencePaused(true)
        setStatus("正在打开主页", style: .working, spinning: true)
        webView.load(request)
    }

    @objc
    fileprivate func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    @objc
    fileprivate func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    @objc
    fileprivate func openNotesArea() {
        navigateToNotesArea(automatic: false)
    }

    private func navigateToNotesArea(automatic: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastNotesNavigationAt) >= 1.2 else { return }

        if !automatic {
            automaticNotesJumpAttempts = 0
        }

        if let currentURL = webView.url, isNotesAreaURL(currentURL) {
            automaticNotesJumpAttempts = 0
            setStatus("已在备忘录", style: .neutral, spinning: false)
            return
        }

        if let currentURL = webView.url, isCloudHomeURL(currentURL), !webView.isLoading {
            if automatic {
                guard automaticNotesJumpAttempts < 3 else {
                    setStatus("已登录，点击备忘录进入", style: .neutral, spinning: false)
                    return
                }
                automaticNotesJumpAttempts += 1
            }

            lastNotesNavigationAt = now
            setStatus("正在进入备忘录", style: .working, spinning: true)
            webView.evaluateJavaScript(Self.notesShortcutScript) { [weak self] result, error in
                guard let self else { return }

                if let error {
                    print("Notes shortcut error: \(error)")
                    self.setStatus("进入备忘录失败", style: .warning, spinning: false)
                    return
                }

                let outcome = (result as? String) ?? "none"
                switch outcome {
                case "already-notes":
                    self.automaticNotesJumpAttempts = 0
                    self.setStatus("已进入备忘录", style: .success, spinning: false)
                case "clicked", "navigating":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self else { return }
                        guard let currentURL = self.webView.url, self.isCloudHomeURL(currentURL), !self.webView.isLoading else {
                            return
                        }
                        self.maybeJumpToNotesIfNeeded()
                    }
                default:
                    self.setStatus("未找到备忘录入口", style: .warning, spinning: false)
                }
            }
            return
        }

        lastNotesNavigationAt = now
        loadNotesURL()
    }

    @objc
    fileprivate func reloadCurrentPage() {
        reloadWebView(reason: "manual")
    }

    @objc
    fileprivate func reloadOrStopLoading() {
        if webView.isLoading {
            webView.stopLoading()
            setStatus("已停止载入", style: .neutral, spinning: false)
            updateNavigationControls()
        } else {
            reloadWebView(reason: "manual")
        }
    }

    @objc
    fileprivate func openCurrentPageInBrowser() {
        guard let url = webView.url, Self.isWebURL(url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    fileprivate func printCurrentPage() {
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic
        webView.printOperation(with: printInfo).run()
    }

    @objc
    fileprivate func showFindPanel() {
        let alert = NSAlert()
        alert.messageText = "查找"
        alert.informativeText = "在当前备忘录页面中查找文字。"
        alert.addButton(withTitle: "查找")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = lastFindString
        input.placeholderString = "输入查找内容"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let query = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        lastFindString = query
        find(query, backwards: false)
    }

    @objc
    fileprivate func findNext() {
        guard !lastFindString.isEmpty else {
            showFindPanel()
            return
        }
        find(lastFindString, backwards: false)
    }

    @objc
    fileprivate func findPrevious() {
        guard !lastFindString.isEmpty else {
            showFindPanel()
            return
        }
        find(lastFindString, backwards: true)
    }

    @objc
    fileprivate func zoomIn() {
        setPageZoom(webView.pageZoom + 0.1)
    }

    @objc
    fileprivate func zoomOut() {
        setPageZoom(webView.pageZoom - 0.1)
    }

    @objc
    fileprivate func resetZoom() {
        setPageZoom(1.0)
    }

    private func find(_ query: String, backwards: Bool) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true

        webView.find(query, configuration: configuration) { [weak self] result in
            guard let self else { return }
            if result.matchFound {
                self.setStatus("", style: .neutral, spinning: false)
            } else {
                self.setStatus("未找到“\(query)”", style: .warning, spinning: false)
            }
        }
    }

    private func setPageZoom(_ value: CGFloat) {
        let zoom = Self.clampedPageZoom(value)
        webView.pageZoom = zoom
        UserDefaults.standard.set(Double(zoom), forKey: Self.pageZoomDefaultsKey)
    }

    private static func savedPageZoom() -> CGFloat {
        let savedValue = UserDefaults.standard.double(forKey: pageZoomDefaultsKey)
        guard savedValue > 0 else {
            return 1.0
        }
        return clampedPageZoom(CGFloat(savedValue))
    }

    private static func clampedPageZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.75), 1.35)
    }

    @objc
    fileprivate func clearLoginData() {
        let alert = NSAlert()
        alert.messageText = "清除登录数据？"
        alert.informativeText = "这会删除本应用保存的华为登录 Cookie 和网站数据。下次打开需要重新登录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.webView.stopLoading()
            self.wasAuthenticated = false
            self.loadingProbeCount = 0
            self.lastLoadingKeepAliveAt = .distantPast
            self.loginRecoveryAttempted = false
            self.loginRecoveryInProgress = false
            self.setStatus("正在清除登录数据", style: .working, spinning: true)
            do {
                try await self.browserSession.clearSessionData()
                self.setStatus("登录数据已清除", style: .success, spinning: false)
                self.loadHome()
            } catch {
                print("Clear login data error: \(error)")
                self.setStatus("清除登录数据失败", style: .error, spinning: false)
            }
        }
    }

    private func scheduleProbe(after delay: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runKeepAliveProbe(reason: reason)
        }
    }

    private func runKeepAliveProbe(reason: String) {
        guard !probeInFlight else {
            scheduleProbe(after: AppConfig.reconnectDelay, reason: "probe-busy")
            return
        }
        guard lastNetworkSatisfied != false else { return }

        if AppConfig.reloadEveryProbe {
            reloadWebView(reason: reason)
            return
        }

        guard webView.url != nil else {
            loadHome()
            return
        }

        guard !webView.isLoading else {
            scheduleProbe(after: AppConfig.reconnectDelay, reason: "probe-loading")
            return
        }

        probeInFlight = true
        setStatus("正在检查连接", style: .working, spinning: true)

        webView.evaluateJavaScript(Self.pageStateScript) { [weak self] result, error in
            guard let self else { return }
            self.probeInFlight = false

            if let error {
                print("Probe error: \(error)")
                self.setStatus("页面检查失败，稍后重试", style: .warning, spinning: false)
                self.scheduleProbe(after: 5, reason: "probe-retry")
                return
            }

            let state = (result as? String) ?? "loading"
            self.diagnostics.log("page_state", fields: [
                "state": state,
                "reason": reason,
                "url": Self.sanitizedURLString(self.webView.url)
            ])
            switch state {
            case "editing":
                self.wasAuthenticated = true
                self.loadingProbeCount = 0
                self.loginRecoveryAttempted = false
                self.persistVerifiedPageCookies()
                self.performNativeKeepAlive(updateStatus: false, reason: "page-editing")
                self.setStatus("正在输入，后台保持连接", style: .neutral, spinning: false)
            case "ok":
                self.wasAuthenticated = true
                self.loadingProbeCount = 0
                self.loginRecoveryAttempted = false
                self.persistVerifiedPageCookies()
                self.performNativeKeepAlive(reason: "page-ok")
            case "login":
                self.handleDetectedLogin(reason: reason)
            case "offline":
                self.loadingProbeCount = 0
                self.setStatus("页面已断线", style: .warning, spinning: false)
                self.reloadWebView(reason: "offline")
            case "loading":
                self.loadingProbeCount += 1
                let status = self.wasAuthenticated ? "正在确认连接" : "正在确认登录态"
                self.setStatus(status, style: .working, spinning: true)
                self.performLoadingKeepAliveIfNeeded(reason: reason)
                let retryDelay: TimeInterval = self.loadingProbeCount >= 5 ? 5.0 : 2.0
                self.scheduleProbe(after: retryDelay, reason: "state-loading")
            default:
                self.loadingProbeCount = 0
                self.browserSession.setCookiePersistencePaused(true)
                self.setStatus("正在确认登录态", style: .working, spinning: true)
                self.scheduleProbe(after: 3.0, reason: "state-unknown")
            }
        }
    }

    func persistCookiesBeforeTermination() async {
        guard webView.url != nil else { return }
        let state = await currentPageState()
        switch state {
        case "login", "offline", nil:
            browserSession.setCookiePersistencePaused(true)
        case "ok", "editing":
            await persistVerifiedPageCookiesNow()
        default:
            browserSession.setCookiePersistencePaused(true)
        }
    }

    private func persistVerifiedPageCookies() {
        Task { @MainActor [weak self] in
            await self?.persistVerifiedPageCookiesNow()
        }
    }

    private func persistVerifiedPageCookiesNow() async {
        wasAuthenticated = true
        loadingProbeCount = 0
        browserSession.setCookiePersistencePaused(false)
        await browserSession.persistCurrentCookies()
    }

    private func currentPageState() async -> String? {
        guard webView.url != nil, !webView.isLoading else { return nil }
        do {
            let value = try await webView.callAsyncJavaScript(
                Self.pageStateScript,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            return (value as? String) ?? "loading"
        } catch {
            return nil
        }
    }

    private enum HeartbeatAuthState: String {
        case alive
        case login
        case failed
        case skipped
    }

    private struct PageHeartbeatPayload: Decodable {
        let status: Int
        let ok: Bool
        let redirected: Bool
        let url: String
        let type: String
    }

    private func performLoadingKeepAliveIfNeeded(reason: String) {
        guard wasAuthenticated else { return }

        let now = Date()
        guard now.timeIntervalSince(lastLoadingKeepAliveAt) >= 30 else {
            return
        }

        lastLoadingKeepAliveAt = now
        performNativeKeepAlive(updateStatus: false, reason: "loading-\(reason)")
    }

    private func performNativeKeepAlive(updateStatus: Bool = true, reason: String) {
        guard webView.url != nil else { return }

        Task { @MainActor [weak self] in
            await self?.performHeartbeat(reason: reason, updateStatus: updateStatus, allowLoginRecovery: true)
        }
    }

    @discardableResult
    private func performHeartbeat(
        reason: String,
        updateStatus: Bool,
        allowLoginRecovery: Bool
    ) async -> HeartbeatAuthState {
        guard !heartbeatInFlight else {
            diagnostics.log("heartbeat_skipped", fields: ["reason": reason, "why": "in-flight"])
            return .skipped
        }

        heartbeatInFlight = true
        defer { heartbeatInFlight = false }

        let cookies = await browserSession.currentCookies()
        let userAgent = await currentPageUserAgent()
        diagnostics.log("heartbeat_start", fields: [
            "reason": reason,
            "cookieCount": "\(cookies.count)",
            "url": Self.sanitizedURLString(webView.url)
        ])

        let nativeResult = await heartbeatClient.check(cookies: cookies, userAgent: userAgent)
        diagnostics.log("heartbeat_native", fields: [
            "reason": reason,
            "result": nativeResult.summary
        ])

        let nativeState = heartbeatState(for: nativeResult)
        switch nativeState {
        case .alive:
            if updateStatus {
                setStatus("已连接 \(Self.timeFormatter.string(from: Date()))", style: .success, spinning: false)
            }
            return .alive
        case .login:
            if allowLoginRecovery {
                handleDetectedLogin(reason: "heartbeat-native-\(reason)")
            }
            return .login
        case .failed, .skipped:
            break
        }

        let pageState = await performPageHeartbeat(reason: reason, updateStatus: updateStatus)
        if pageState == .login, allowLoginRecovery {
            handleDetectedLogin(reason: "heartbeat-page-\(reason)")
        }
        return pageState
    }

    private func performPageHeartbeat(reason: String, updateStatus: Bool) async -> HeartbeatAuthState {
        guard webView.url != nil else { return .failed }

        do {
            let value = try await webView.callAsyncJavaScript(
                Self.heartbeatScript,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            guard let jsonString = value as? String,
                  let data = jsonString.data(using: .utf8) else {
                diagnostics.log("heartbeat_page", fields: [
                    "reason": reason,
                    "error": "non-json-result"
                ])
                return .failed
            }

            let payload = try JSONDecoder().decode(PageHeartbeatPayload.self, from: data)
            diagnostics.log("heartbeat_page", fields: [
                "reason": reason,
                "status": "\(payload.status)",
                "ok": "\(payload.ok)",
                "redirected": "\(payload.redirected)",
                "type": payload.type,
                "url": Self.sanitizedURLString(URL(string: payload.url))
            ])

            let state = heartbeatState(for: payload)
            if state == .alive, updateStatus {
                setStatus("已连接 \(Self.timeFormatter.string(from: Date()))", style: .success, spinning: false)
            }
            return state
        } catch {
            diagnostics.log("heartbeat_page_error", fields: [
                "reason": reason,
                "error": "\(error)"
            ])
            return .failed
        }
    }

    private func currentPageUserAgent() async -> String? {
        do {
            return try await webView.callAsyncJavaScript(
                "navigator.userAgent",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? String
        } catch {
            return nil
        }
    }

    private func heartbeatState(for result: HeartbeatResult) -> HeartbeatAuthState {
        if let redirectLocation = result.redirectLocation,
           let redirectURL = URL(string: redirectLocation, relativeTo: HeartbeatClient.sessionRefreshURL),
           isLoginLikeURL(redirectURL) {
            return .login
        }

        if let finalURLString = result.finalURLString,
           let finalURL = URL(string: finalURLString),
           isLoginLikeURL(finalURL) {
            return .login
        }

        if result.isHTTPRedirect {
            return .login
        }

        guard let statusCode = result.statusCode else {
            return .failed
        }

        if statusCode == 401 || statusCode == 403 {
            return .login
        }

        guard statusCode == 200,
              let finalURLString = result.finalURLString,
              let finalURL = URL(string: finalURLString),
              finalURL.host?.lowercased() == "cloud.huawei.com" else {
            return .failed
        }

        return .alive
    }

    private func heartbeatState(for payload: PageHeartbeatPayload) -> HeartbeatAuthState {
        if payload.type == "opaqueredirect" || payload.redirected {
            return .login
        }

        if let url = URL(string: payload.url), isLoginLikeURL(url) {
            return .login
        }

        if payload.status == 401 || payload.status == 403 {
            return .login
        }

        return payload.status == 200 && payload.ok ? .alive : .failed
    }

    private func recoverAfterResume(reason: String) {
        guard initialLoadStarted else { return }

        diagnostics.log("resume_recovery_start", fields: [
            "reason": reason,
            "url": Self.sanitizedURLString(webView.url)
        ])
        browserSession.setCookiePersistencePaused(true)
        setStatus("正在恢复连接", style: .working, spinning: true)

        Task { @MainActor [weak self] in
            guard let self else { return }

            if AppConfig.restoreCookieVaultOnLaunch {
                do {
                    let restoredCount = try await self.browserSession.restoreCookies()
                    self.diagnostics.log("resume_cookie_restore", fields: [
                        "reason": reason,
                        "count": "\(restoredCount)"
                    ])
                } catch {
                    self.diagnostics.log("resume_cookie_restore_error", fields: [
                        "reason": reason,
                        "error": "\(error)"
                    ])
                }
            }

            let heartbeatState = await self.performHeartbeat(
                reason: "resume-\(reason)",
                updateStatus: false,
                allowLoginRecovery: false
            )
            self.diagnostics.log("resume_heartbeat_result", fields: [
                "reason": reason,
                "state": heartbeatState.rawValue
            ])

            if heartbeatState == .login {
                self.handleDetectedLogin(reason: "resume-\(reason)")
            } else {
                if self.webView.url == nil {
                    self.loadNotesURL()
                }
                self.scheduleProbe(after: 2.5, reason: "resume-\(reason)")
            }
        }
    }

    private func handleDetectedLogin(reason: String) {
        wasAuthenticated = false
        loadingProbeCount = 0
        browserSession.setCookiePersistencePaused(true)
        diagnostics.log("login_detected", fields: [
            "reason": reason,
            "url": Self.sanitizedURLString(webView.url),
            "recoveryAttempted": "\(loginRecoveryAttempted)",
            "recoveryInProgress": "\(loginRecoveryInProgress)"
        ])

        guard AppConfig.restoreCookieVaultOnLaunch else {
            setStatus("需要重新登录", style: .error, spinning: false)
            return
        }

        guard !loginRecoveryInProgress else {
            setStatus("正在尝试恢复登录态", style: .working, spinning: true)
            return
        }

        guard !loginRecoveryAttempted else {
            setStatus("需要重新登录", style: .error, spinning: false)
            return
        }

        loginRecoveryAttempted = true
        loginRecoveryInProgress = true
        setStatus("正在尝试恢复登录态", style: .working, spinning: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loginRecoveryInProgress = false }

            do {
                let restoredCount = try await self.browserSession.restoreCookies()
                self.diagnostics.log("login_recovery_cookie_restore", fields: [
                    "reason": reason,
                    "count": "\(restoredCount)"
                ])
                self.loadNotesURL()
                self.scheduleProbe(after: 4.0, reason: "login-recovery")
            } catch {
                self.diagnostics.log("login_recovery_error", fields: [
                    "reason": reason,
                    "error": "\(error)"
                ])
                self.setStatus("需要重新登录", style: .error, spinning: false)
            }
        }
    }

    private func reloadWebView(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastReloadAt) >= AppConfig.minimumReloadGap else {
            return
        }
        lastReloadAt = now

        setStatus("正在刷新", style: .working, spinning: true)
        browserSession.setCookiePersistencePaused(true)
        if webView.url == nil {
            openNotesArea()
        } else {
            webView.reload()
        }
    }

    private func updateNavigationControls() {
        toolbarItemsByIdentifier[.huaweiBack]?.isEnabled = webView.canGoBack
        toolbarItemsByIdentifier[.huaweiForward]?.isEnabled = webView.canGoForward

        guard let reloadStopItem = toolbarItemsByIdentifier[.huaweiReloadStop] else {
            return
        }

        let isLoading = webView.isLoading
        let symbolName = isLoading ? "xmark" : "arrow.clockwise"
        let label = isLoading ? "停止" : "刷新"
        reloadStopItem.label = label
        reloadStopItem.paletteLabel = label
        reloadStopItem.toolTip = label
        reloadStopItem.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    private func hideLaunchPlaceholderIfNeeded() {
        guard !hasHiddenLaunchPlaceholder else { return }
        hasHiddenLaunchPlaceholder = true
        launchSpinner.stopAnimation(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            launchPlaceholder.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.launchPlaceholder.removeFromSuperview()
            }
        }
    }

    private func setStatus(_ text: String, style: StatusStyle, spinning: Bool) {
        window.subtitle = ""
        switch style {
        case .warning, .error:
            showStatusBanner(text, style: style)
        default:
            hideStatusBanner()
        }
        updateNavigationControls()
    }

    private func showStatusBanner(_ text: String, style: StatusStyle) {
        statusBannerHideWorkItem?.cancel()
        statusBanner.isHidden = false
        statusBannerLabel.stringValue = text
        statusBannerLabel.textColor = style == .error ? .systemRed : .systemOrange
        statusBanner.layer?.backgroundColor = Self.bannerBackgroundColor(for: style).cgColor
        statusBanner.layer?.borderColor = Self.bannerBorderColor(for: style).cgColor

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            statusBanner.animator().alphaValue = 1
        }

        if style == .warning {
            let workItem = DispatchWorkItem { [weak self] in
                self?.hideStatusBanner()
            }
            statusBannerHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: workItem)
        }
    }

    private func hideStatusBanner() {
        statusBannerHideWorkItem?.cancel()
        statusBannerHideWorkItem = nil
        guard !statusBanner.isHidden || statusBanner.alphaValue > 0 else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            statusBanner.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.statusBanner.alphaValue <= 0 {
                    self.statusBanner.isHidden = true
                }
            }
        }
    }

    private func isNotesAreaURL(_ url: URL) -> Bool {
        let absolute = url.absoluteString.lowercased()
        return absolute.contains("#/notepad") || absolute.contains("/notepad")
    }

    private func isCloudHomeURL(_ url: URL) -> Bool {
        guard let host = url.host, host.contains("cloud.huawei.com") else { return false }
        let absolute = url.absoluteString.lowercased()
        return url.path == "/" || url.path == "/home" || absolute.contains("#/home")
    }

    private func isLoginLikeURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let components = Self.normalizedPathComponents(for: url)
        let loginHosts = [
            "id1.cloud.huawei.com",
            "login.cloud.huawei.com",
            "passport.huawei.com"
        ]

        if loginHosts.contains(host)
            || host.hasPrefix("id1.")
            || host.hasPrefix("login.")
            || host.hasPrefix("passport.") {
            return true
        }

        let loginComponents: Set<String> = [
            "login",
            "logout",
            "signin",
            "passport",
            "oauth",
            "sso",
            "cas"
        ]
        if components.contains(where: { loginComponents.contains($0) }) {
            return true
        }

        let knownLoginComponents: Set<String> = [
            "v2logout",
            "cloudiframelogin.html"
        ]
        return components.contains { component in
            knownLoginComponents.contains(component)
                || component.hasSuffix("login.html")
        }
    }

    private static func normalizedPathComponents(for url: URL) -> [String] {
        url.pathComponents
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func sanitizedURLString(_ url: URL?) -> String {
        guard let url else { return "nil" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    private func updateCookiePersistence(for url: URL?) {
        guard let url else { return }
        if isLoginLikeURL(url) {
            browserSession.setCookiePersistencePaused(true)
        }
    }

    private func maybeJumpToNotesIfNeeded() {
        guard let currentURL = webView.url else { return }
        guard let host = currentURL.host, host.contains("cloud.huawei.com") else { return }
        let absolute = currentURL.absoluteString.lowercased()
        let isLoginLike = isLoginLikeURL(currentURL)
        let isNotesLike = isNotesAreaURL(currentURL)
        let isHomeLike = currentURL.path == "/" || currentURL.path == "/home" || absolute == AppConfig.homeURL.absoluteString.lowercased()

        guard !isLoginLike, !isNotesLike, isHomeLike else { return }
        navigateToNotesArea(automatic: true)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadingProbeCount = 0
        updateCookiePersistence(for: webView.url)
        setStatus("正在载入", style: .working, spinning: true)
        updateNavigationControls()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateCookiePersistence(for: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideLaunchPlaceholderIfNeeded()
        if let currentURL = webView.url, isNotesAreaURL(currentURL) {
            automaticNotesJumpAttempts = 0
            setStatus("正在确认登录态", style: .working, spinning: true)
        } else if let currentURL = webView.url, isLoginLikeURL(currentURL) {
            handleDetectedLogin(reason: "navigation-finished")
        } else {
            setStatus("页面已载入", style: .success, spinning: false)
        }
        maybeJumpToNotesIfNeeded()
        scheduleProbe(after: 1.2, reason: "post-load")
        updateNavigationControls()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        hideLaunchPlaceholderIfNeeded()
        print("Navigation error: \(error)")
        setStatus("载入失败，稍后重试", style: .warning, spinning: false)
        scheduleProbe(after: AppConfig.reconnectDelay, reason: "navigation-failed")
        updateNavigationControls()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        hideLaunchPlaceholderIfNeeded()
        print("Provisional navigation error: \(error)")
        setStatus("暂时无法连接", style: .warning, spinning: false)
        scheduleProbe(after: AppConfig.reconnectDelay, reason: "provisional-failed")
        updateNavigationControls()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setStatus("内容异常，正在恢复", style: .warning, spinning: false)
        reloadWebView(reason: "web-content-terminated")
        updateNavigationControls()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        presentPopup(using: configuration, request: navigationAction.request)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if isLoginLikeURL(url) {
            browserSession.setCookiePersistencePaused(true)
        } else if navigationAction.targetFrame?.isMainFrame == true {
            updateCookiePersistence(for: url)
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "data" {
            decisionHandler(.allow)
            return
        }

        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    private func presentPopup(using configuration: WKWebViewConfiguration, request: URLRequest?) -> WKWebView {
        let controller = PopupWindowController(
            browserSession: browserSession,
            configuration: configuration,
            initialRequest: request
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.popupControllers.removeAll { $0 === controller }
        }
        popupControllers.append(controller)
        controller.showWindow(nil)
        return controller.webView
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let pageStateScript = """
    (() => {
      const title = (document.title || '').toLowerCase();
      const href = (location.href || '').toLowerCase();
      const text = ((document.body && document.body.innerText) || '').slice(0, 5000).toLowerCase();
      const notesURL = href.includes('#/notepad') || href.includes('/notepad');
      const visible = element => {
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 8 &&
          rect.height > 8 &&
          style.visibility !== 'hidden' &&
          style.display !== 'none' &&
          Number(style.opacity || 1) > 0.02;
      };
      const loginLikeURL = rawURL => {
        try {
          const url = new URL(rawURL, location.href);
          const host = url.hostname.toLowerCase();
          const path = url.pathname.toLowerCase();
          const loginHost =
            host === 'id1.cloud.huawei.com' ||
            host === 'login.cloud.huawei.com' ||
            host === 'passport.huawei.com' ||
            host.startsWith('id1.') ||
            host.startsWith('login.') ||
            host.startsWith('passport.');

          const components = path
            .split('/')
            .map(component => component.trim().toLowerCase())
            .filter(Boolean);
          const loginComponents = new Set([
            'login',
            'logout',
            'signin',
            'passport',
            'oauth',
            'sso',
            'cas'
          ]);
          const knownLoginComponents = new Set([
            'v2logout',
            'cloudiframelogin.html'
          ]);
          const loginPath = components.some(component =>
            loginComponents.has(component) ||
            knownLoginComponents.has(component) ||
            component.endsWith('login.html')
          );

          return loginHost || loginPath;
        } catch {
          return false;
        }
      };

      const visibleFrames = Array.from(document.querySelectorAll('iframe')).filter(visible);
      const loginFrame = visibleFrames.some(frame => loginLikeURL(frame.src || ''));
      const strongLoginFrame = visibleFrames.some(frame => {
        try {
          const url = new URL(frame.src || '', location.href);
          const host = url.hostname.toLowerCase();
          const path = url.pathname.toLowerCase();
          return host === 'id1.cloud.huawei.com' && path.includes('cloudiframelogin.html');
        } catch {
          return false;
        }
      });
      const passwordInput = Boolean(document.querySelector('input[type="password"]'));
      const accountLoginText = /(登录|扫码登录|密码登录|验证码|忘记密码|华为账号|华为帐号)/i.test(`${title} ${text}`);

      if (loginLikeURL(href) || strongLoginFrame || (loginFrame && (passwordInput || accountLoginText)) || (passwordInput && accountLoginText)) {
        return 'login';
      }

      if (/(offline|network error|connection lost|重新连接|连接已断开|网络异常|离线|当前网络不可用|请检查网络)/i.test(`${title} ${href} ${text}`)) {
        return 'offline';
      }

      const active = document.activeElement;
      const editing = Boolean(
        active &&
        (
          active.matches('input, textarea, [contenteditable="true"]') ||
          (active.closest && active.closest('[contenteditable="true"]'))
        )
      );
      const notesText = /(全部笔记|备忘录|我的收藏|待办|搜索|无笔记|新建笔记|分类|筛选项|回收站)/i.test(text);
      const authenticatedNotes = notesURL && notesText && !passwordInput;
      if (authenticatedNotes && editing) return 'editing';
      if (authenticatedNotes) return 'ok';

      return 'loading';
    })();
    """

    private static let heartbeatScript = """
    const traceId = `00001-${Date.now().toString(36)}`;
    const response = await fetch('/refreshLoginStatus', {
      method: 'POST',
      credentials: 'include',
      cache: 'no-store',
      headers: {
        'Content-Type': 'application/json;charset=UTF-8',
        'x-hw-trace-id': traceId
      },
      body: JSON.stringify({ traceId })
    });
    return JSON.stringify({
      status: response.status,
      ok: response.ok,
      redirected: response.redirected,
      url: response.url || '',
      type: response.type || ''
    });
    """

    private static let notesShortcutScript = """
    (() => {
      const notesURL = 'https://cloud.huawei.com/home#/notepad/note/allNote';
      const visible = element => {
        if (!element) return false;
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 16 && rect.height > 16;
      };

      const href = (location.href || '').toLowerCase();
      if (href.includes('#/notepad') || href.includes('/notepad')) {
        return 'already-notes';
      }

      const candidates = Array.from(document.querySelectorAll('a, button, [role="button"], [tabindex], div, span'));
      const ranked = candidates
        .map(element => {
          if (!visible(element)) return null;
          const text = ((element.innerText || element.textContent || '') + '').replace(/\\s+/g, '');
          const link = ((element.getAttribute && element.getAttribute('href')) || '').toLowerCase();
          const label = ((element.getAttribute && (element.getAttribute('aria-label') || element.getAttribute('title'))) || '').replace(/\\s+/g, '');
          const rect = element.getBoundingClientRect();
          let score = 0;
          if (link.includes('notepad')) score += 100;
          if (text === '备忘录' || label === '备忘录') score += 80;
          if (text.includes('备忘录') || label.includes('备忘录')) score += 30;
          if (rect.width >= 48 && rect.height >= 48) score += 10;
          if (rect.top > window.innerHeight * 0.15 && rect.left > window.innerWidth * 0.1) score += 8;
          if (text.length > 12) score -= 20;
          return score > 0 ? { element, score } : null;
        })
        .filter(Boolean)
        .sort((a, b) => b.score - a.score);

      const target = ranked[0] && ranked[0].element;
      if (target) {
        const clickable = target.closest('a, button, [role="button"], [tabindex]') || target;
        const rect = clickable.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        for (const type of ['pointerdown', 'mousedown', 'mouseup', 'click']) {
          clickable.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
        }
        if (typeof clickable.click === 'function') clickable.click();
        setTimeout(() => {
          if (!(location.href || '').toLowerCase().includes('#/notepad')) {
            location.href = notesURL;
          }
        }, 500);
        return 'clicked';
      }

      location.href = notesURL;
      return 'navigating';
    })();
    """

}

@MainActor
final class PopupWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    private let browserSession: BrowserSession
    let webView: WKWebView
    var onClose: (() -> Void)?

    init(browserSession: BrowserSession, configuration: WKWebViewConfiguration, initialRequest: URLRequest?) {
        self.browserSession = browserSession
        browserSession.preparePopupConfiguration(configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor

        window.title = AppConfig.appDisplayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = webView
        window.center()

        if let initialRequest {
            webView.load(initialRequest)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        super.close()
        onClose?()
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let request = navigationAction.request as URLRequest? {
            webView.load(request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "data" {
            decisionHandler(.allow)
            return
        }

        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
