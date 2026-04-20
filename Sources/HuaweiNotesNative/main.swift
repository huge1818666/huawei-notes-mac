import AppKit
import Network
import WebKit

enum AppConfig {
    static let bundleIdentifier = "com.codex.huaweinotes"
    static let appDisplayName = "华为备忘录"
    static let defaultHomeURL = "https://cloud.huawei.com/"
    static let defaultNotesURL = "https://cloud.huawei.com/home#/notepad/note/allNote"
    static let defaultKeepAliveSeconds: TimeInterval = 240
    static let minimumReloadGap: TimeInterval = 15
    static let reconnectDelay: TimeInterval = 1.5

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
    private var controller: NotesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotesWindowController()
        configureMainMenu()
        controller?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.tearDown()
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
        appMenu.addItem(withTitle: "关于\(AppConfig.appDisplayName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
}

extension NSToolbarItem.Identifier {
    static let huaweiHome = NSToolbarItem.Identifier("com.codex.huaweinotes.toolbar.home")
    static let huaweiNotes = NSToolbarItem.Identifier("com.codex.huaweinotes.toolbar.notes")
    static let huaweiReload = NSToolbarItem.Identifier("com.codex.huaweinotes.toolbar.reload")
}

@MainActor
final class NotesWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate {
    private let window: NSWindow
    private let rootView = NSView()
    private let contentBackgroundView = NSView()
    private let webView: WKWebView
    private let topChromeBlend = NSVisualEffectView()

    private let statusCard = NSVisualEffectView()
    private let statusSpinner = NSProgressIndicator()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "正在准备华为云空间")

    private var keepAliveTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "HuaweiNotesNative.PathMonitor")
    private var lastNetworkSatisfied: Bool?
    private var lastReloadAt = Date.distantPast
    private var lastInactiveAt: Date?
    private var probeInFlight = false
    private var lifetimeActivity: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var statusHideWorkItem: DispatchWorkItem?
    private var lastNotesNavigationAt = Date.distantPast
    private var popupControllers: [PopupWindowController] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        configureWindow()
        configureToolbar()
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
        if webView.url == nil {
            loadHome()
        }
    }

    func tearDown() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        pathMonitor.cancel()
        NotificationCenter.default.removeObserver(self)
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
        window.toolbarStyle = .unifiedCompact
        if #available(macOS 15.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.center()
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
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .huaweiHome, .huaweiNotes, .huaweiReload]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .huaweiHome, .huaweiNotes, .huaweiReload]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .huaweiHome:
            return makeToolbarItem(
                identifier: itemIdentifier,
                symbolName: "house",
                label: "主页",
                action: #selector(loadHome)
            )
        case .huaweiNotes:
            return makeToolbarItem(
                identifier: itemIdentifier,
                symbolName: "note.text",
                label: "备忘录",
                action: #selector(openNotesArea)
            )
        case .huaweiReload:
            return makeToolbarItem(
                identifier: itemIdentifier,
                symbolName: "arrow.clockwise",
                label: "刷新",
                action: #selector(reloadCurrentPage)
            )
        default:
            return nil
        }
    }

    private func configureLayout() {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = rootView

        let contentTopAnchor: NSLayoutYAxisAnchor
        if let contentGuide = window.contentLayoutGuide as? NSLayoutGuide {
            contentTopAnchor = contentGuide.topAnchor
        } else {
            contentTopAnchor = rootView.topAnchor
        }

        contentBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        contentBackgroundView.wantsLayer = true
        rootView.addSubview(contentBackgroundView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(webView)

        topChromeBlend.translatesAutoresizingMaskIntoConstraints = false
        topChromeBlend.material = .titlebar
        topChromeBlend.blendingMode = .behindWindow
        topChromeBlend.state = .followsWindowActiveState
        topChromeBlend.wantsLayer = true
        rootView.addSubview(topChromeBlend)
        configureCard(statusCard)

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.controlSize = .small
        statusSpinner.style = .spinning
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.setContentHuggingPriority(.required, for: .horizontal)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = StatusStyle.neutral.color.cgColor

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusStack = NSStackView(views: [statusSpinner, statusDot, statusLabel])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5
        statusStack.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        statusCard.addSubview(statusStack)
        rootView.addSubview(statusCard)
        statusCard.alphaValue = 0

        NSLayoutConstraint.activate([
            contentBackgroundView.topAnchor.constraint(equalTo: contentTopAnchor),
            contentBackgroundView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            contentBackgroundView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentBackgroundView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            webView.topAnchor.constraint(equalTo: contentTopAnchor),
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            topChromeBlend.topAnchor.constraint(equalTo: rootView.topAnchor),
            topChromeBlend.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topChromeBlend.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            topChromeBlend.bottomAnchor.constraint(equalTo: contentTopAnchor),

            statusCard.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            statusCard.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            statusCard.widthAnchor.constraint(lessThanOrEqualToConstant: 148),

            statusStack.topAnchor.constraint(equalTo: statusCard.topAnchor),
            statusStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor),

            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    private func configureCard(_ view: NSVisualEffectView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.68).cgColor
        view.layer?.shadowOpacity = 0
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
        let darkMode = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        contentBackgroundView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        webView.underPageBackgroundColor = .windowBackgroundColor

        let borderColor = (darkMode ? NSColor.white : NSColor.separatorColor).withAlphaComponent(darkMode ? 0.08 : 0.16)
        let backgroundColor = (darkMode ? NSColor.black : NSColor.windowBackgroundColor).withAlphaComponent(darkMode ? 0.28 : 0.72)

        topChromeBlend.layer?.backgroundColor = (darkMode ? NSColor.white : NSColor.white)
            .withAlphaComponent(darkMode ? 0.04 : 0.07)
            .cgColor
        statusCard.layer?.borderColor = borderColor.cgColor
        statusCard.layer?.backgroundColor = backgroundColor.cgColor
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
    }

    private func beginLifetimeActivity() {
        lifetimeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep Huawei Notes responsive while preserving session state"
        )
    }

    private func startKeepAliveLoop() {
        keepAliveTimer?.invalidate()
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

                if isSatisfied, previous == false {
                    self.setStatus("网络已恢复，正在重新连接", style: .working, spinning: true)
                    self.scheduleProbe(after: AppConfig.reconnectDelay, reason: "network-restored")
                } else if !isSatisfied {
                    self.setStatus("当前离线，网络恢复后会自动重连", style: .warning, spinning: false)
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    @objc
    private func handleAppDidBecomeActive() {
        guard let lastInactiveAt else {
            scheduleProbe(after: 0.8, reason: "launch")
            return
        }

        let idleTime = Date().timeIntervalSince(lastInactiveAt)
        if idleTime >= 20 {
            setStatus("正在恢复连接", style: .working, spinning: true)
            scheduleProbe(after: 0.8, reason: "resumed")
        }
    }

    @objc
    private func handleAppDidResignActive() {
        lastInactiveAt = Date()
    }

    @objc
    fileprivate func loadHome() {
        let request = URLRequest(url: AppConfig.homeURL, cachePolicy: .reloadIgnoringLocalCacheData)
        setStatus("正在打开主页", style: .working, spinning: true)
        webView.load(request)
    }

    @objc
    fileprivate func openNotesArea() {
        let now = Date()
        guard now.timeIntervalSince(lastNotesNavigationAt) >= 1.2 else { return }

        if let currentURL = webView.url, isNotesAreaURL(currentURL) {
            setStatus("已在备忘录", style: .neutral, spinning: false)
            return
        }

        if let currentURL = webView.url, isCloudHomeURL(currentURL), !webView.isLoading {
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
                case "clicked", "already-notes":
                    break
                default:
                    self.setStatus("未找到备忘录入口", style: .warning, spinning: false)
                }
            }
            return
        }

        lastNotesNavigationAt = now
        loadHome()
    }

    @objc
    fileprivate func reloadCurrentPage() {
        reloadWebView(reason: "manual")
    }

    private func scheduleProbe(after delay: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runKeepAliveProbe(reason: reason)
        }
    }

    private func runKeepAliveProbe(reason: String) {
        guard !probeInFlight else { return }
        guard lastNetworkSatisfied != false else { return }

        if AppConfig.reloadEveryProbe {
            reloadWebView(reason: reason)
            return
        }

        guard webView.url != nil else {
            loadHome()
            return
        }

        guard !webView.isLoading else { return }

        probeInFlight = true
        setStatus("正在检查连接", style: .working, spinning: true)

        webView.evaluateJavaScript(Self.pageStateScript) { [weak self] result, error in
            guard let self else { return }
            self.probeInFlight = false

            if let error {
                print("Probe error: \(error)")
                self.setStatus("页面检查失败，准备重新载入", style: .warning, spinning: false)
                self.reloadWebView(reason: "probe-error")
                return
            }

            let state = (result as? String) ?? "ok"
            switch state {
            case "editing":
                self.setStatus("正在输入，已跳过", style: .neutral, spinning: false)
            case "login":
                self.setStatus("需要重新登录", style: .error, spinning: false)
            case "offline":
                self.setStatus("页面已断线", style: .warning, spinning: false)
                self.reloadWebView(reason: "offline")
            default:
                self.performNativeKeepAlive()
            }
        }
    }

    private func performNativeKeepAlive() {
        guard let url = webView.url else { return }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 20
            configuration.httpShouldSetCookies = true
            configuration.httpCookieStorage = HTTPCookieStorage()

            if let storage = configuration.httpCookieStorage {
                let host = url.host ?? ""
                for cookie in cookies where host.hasSuffix(cookie.domain.replacingOccurrences(of: ".", with: "")) || host.contains(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                    storage.setCookie(cookie)
                }
            }

            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "GET"
            request.setValue("1", forHTTPHeaderField: "X-Codex-Keepalive")

            let task = URLSession(configuration: configuration).dataTask(with: request) { _, response, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let error {
                        print("Keepalive error: \(error)")
                        self.setStatus("连接异常，正在刷新", style: .warning, spinning: false)
                        self.reloadWebView(reason: "ping-error")
                        return
                    }

                    if let response = response as? HTTPURLResponse, !(200 ... 399).contains(response.statusCode) {
                        self.setStatus("服务异常，正在刷新", style: .warning, spinning: false)
                        self.reloadWebView(reason: "ping-status-\(response.statusCode)")
                        return
                    }

                    self.setStatus("已连接 \(Self.timeFormatter.string(from: Date()))", style: .success, spinning: false)
                }
            }
            task.resume()
        }
    }

    private func reloadWebView(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastReloadAt) >= AppConfig.minimumReloadGap else {
            return
        }
        lastReloadAt = now

        setStatus("正在刷新", style: .working, spinning: true)
        if webView.url == nil {
            openNotesArea()
        } else {
            webView.reload()
        }
    }

    private func setStatus(_ text: String, style: StatusStyle, spinning: Bool) {
        statusHideWorkItem?.cancel()
        statusLabel.stringValue = text
        statusLabel.textColor = style == .neutral ? .secondaryLabelColor : .labelColor
        statusDot.layer?.backgroundColor = style.color.cgColor

        if spinning {
            statusSpinner.startAnimation(nil)
            statusDot.isHidden = true
        } else {
            statusSpinner.stopAnimation(nil)
            statusDot.isHidden = false
        }

        showStatusCard()

        if !spinning, style == .success || style == .neutral {
            let workItem = DispatchWorkItem { [weak self] in
                self?.hideStatusCard()
            }
            statusHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
        } else if !spinning {
            let workItem = DispatchWorkItem { [weak self] in
                self?.hideStatusCard()
            }
            statusHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4, execute: workItem)
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

    private func showStatusCard() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            statusCard.animator().alphaValue = 1
        }
    }

    private func hideStatusCard() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            statusCard.animator().alphaValue = 0
        }
    }

    private func maybeJumpToNotesIfNeeded() {
        guard let currentURL = webView.url else { return }
        guard let host = currentURL.host, host.contains("cloud.huawei.com") else { return }
        let absolute = currentURL.absoluteString.lowercased()
        let isLoginLike = absolute.contains("login") || absolute.contains("auth") || absolute.contains("account")
        let isNotesLike = isNotesAreaURL(currentURL)
        let isHomeLike = currentURL.path == "/" || currentURL.path == "/home" || absolute == AppConfig.homeURL.absoluteString.lowercased()

        guard !isLoginLike, !isNotesLike, isHomeLike else { return }
        openNotesArea()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setStatus("正在载入", style: .working, spinning: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let currentURL = webView.url, isNotesAreaURL(currentURL) {
            setStatus("已进入备忘录", style: .success, spinning: false)
        } else {
            setStatus("页面已载入", style: .success, spinning: false)
        }
        maybeJumpToNotesIfNeeded()
        scheduleProbe(after: 1.2, reason: "post-load")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("Navigation error: \(error)")
        setStatus("载入失败，稍后重试", style: .warning, spinning: false)
        scheduleProbe(after: AppConfig.reconnectDelay, reason: "navigation-failed")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("Provisional navigation error: \(error)")
        setStatus("暂时无法连接", style: .warning, spinning: false)
        scheduleProbe(after: AppConfig.reconnectDelay, reason: "provisional-failed")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setStatus("内容异常，正在恢复", style: .warning, spinning: false)
        reloadWebView(reason: "web-content-terminated")
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

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "data" {
            decisionHandler(.allow)
            return
        }

        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    private func presentPopup(using configuration: WKWebViewConfiguration, request: URLRequest?) -> WKWebView {
        let controller = PopupWindowController(configuration: configuration, initialRequest: request)
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
      const active = document.activeElement;
      const editing = Boolean(
        active &&
        (
          active.matches('input, textarea, [contenteditable="true"]') ||
          (active.closest && active.closest('[contenteditable="true"]'))
        )
      );
      if (editing) return 'editing';

      const title = (document.title || '').toLowerCase();
      const href = (location.href || '').toLowerCase();
      const text = ((document.body && document.body.innerText) || '').slice(0, 5000).toLowerCase();
      const combined = `${title} ${href} ${text}`;

      if (/(login|signin|passport|auth|account|登录|验证码|华为账号|华为帐号)/i.test(combined)) {
        return 'login';
      }

      if (/(offline|network error|connection lost|重新连接|连接已断开|网络异常|离线|当前网络不可用|请检查网络)/i.test(combined)) {
        return 'offline';
      }

      return 'ok';
    })();
    """

    private static let notesShortcutScript = """
    (() => {
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

      const candidates = Array.from(document.querySelectorAll('a, button, [role="button"], div, span'));
      const target = candidates.find(element => {
        if (!visible(element)) return false;
        const text = ((element.innerText || element.textContent || '') + '').replace(/\\s+/g, '');
        return text === '备忘录' || text.includes('备忘录');
      });

      if (!target) return 'none';

      const clickable = target.closest('a, button, [role="button"]') || target;
      clickable.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      if (typeof clickable.click === 'function') clickable.click();
      return 'clicked';
    })();
    """

}

@MainActor
final class PopupWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var onClose: (() -> Void)?

    init(configuration: WKWebViewConfiguration, initialRequest: URLRequest?) {
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
