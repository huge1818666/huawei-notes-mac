import Foundation
import WebKit

@MainActor
public final class BrowserSession: NSObject, WKHTTPCookieStoreObserver {
    public static let profileIdentifier = UUID(uuidString: "7D37E4A5-4A3F-4B42-B3E0-D9B07B46D92E")!

    public let dataStore: WKWebsiteDataStore
    public let cookieVault: CookieVault

    private var saveTask: Task<Void, Never>?
    private var isRestoringCookies = false
    private var isClearingSessionData = false
    private var isCookiePersistencePaused = false
    private var hadCookieChangesWhilePaused = false

    public private(set) var lastCookieSaveError: Error?

    public init(
        dataStore: WKWebsiteDataStore = BrowserSession.makePersistentDataStore(),
        cookieVault: CookieVault = CookieVault()
    ) {
        self.dataStore = dataStore
        self.cookieVault = cookieVault
        super.init()
        cookieStore.add(self)
    }

    deinit {
        saveTask?.cancel()
    }

    public var cookieStore: WKHTTPCookieStore {
        dataStore.httpCookieStore
    }

    public static func makePersistentDataStore() -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: profileIdentifier)
    }

    public func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(Self.nativePolishScript)
        return configuration
    }

    public func preparePopupConfiguration(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(Self.nativePolishScript)
    }

    public func restoreCookies() async throws -> Int {
        let cookies = try cookieVault.restoreCookies()
        guard !cookies.isEmpty else {
            return 0
        }

        isRestoringCookies = true
        defer { isRestoringCookies = false }

        for cookie in cookies {
            await setCookie(cookie)
        }

        return cookies.count
    }

    public func setCookiePersistencePaused(_ paused: Bool) {
        guard isCookiePersistencePaused != paused else {
            return
        }
        isCookiePersistencePaused = paused
        if paused {
            saveTask?.cancel()
            saveTask = nil
        } else if hadCookieChangesWhilePaused {
            hadCookieChangesWhilePaused = false
            scheduleDebouncedSave()
        }
    }

    public func persistCurrentCookies(force: Bool = false) async {
        guard force || !isCookiePersistencePaused else {
            return
        }

        let cookies = await currentCookies()
        do {
            try cookieVault.save(cookies)
            lastCookieSaveError = nil
        } catch {
            lastCookieSaveError = error
        }
    }

    public func clearSessionData() async throws {
        isClearingSessionData = true
        saveTask?.cancel()
        defer { isClearingSessionData = false }

        try cookieVault.delete()
        await removeAllWebsiteData()
    }

    public func invalidate() {
        saveTask?.cancel()
        cookieStore.remove(self)
    }

    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard !isRestoringCookies, !isClearingSessionData else {
            return
        }

        if isCookiePersistencePaused {
            hadCookieChangesWhilePaused = true
            return
        }

        scheduleDebouncedSave()
    }

    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistCurrentCookies()
        }
    }

    public func currentCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private func removeAllWebsiteData() async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private static let nativePolishScript = WKUserScript(
        source: """
        (() => {
          if (window.__huaweiNotesNativePolishInstalled) return;
          window.__huaweiNotesNativePolishInstalled = true;

          const style = document.createElement('style');
          style.textContent = `
            html, body {
              background: Canvas !important;
              -webkit-font-smoothing: antialiased;
            }
          `;
          document.documentElement.appendChild(style);

          const hideCookieNotice = () => {
            const nodes = Array.from(document.querySelectorAll('body *'));
            for (const node of nodes) {
              const text = ((node.innerText || node.textContent || '') + '').replace(/\\s+/g, ' ');
              if (!text.includes('我们使用 Cookie')) continue;

              let target = node;
              for (let i = 0; i < 4 && target.parentElement; i += 1) {
                const rect = target.getBoundingClientRect();
                const parentRect = target.parentElement.getBoundingClientRect();
                if (parentRect.height <= 160 && parentRect.width >= window.innerWidth * 0.45) {
                  target = target.parentElement;
                } else if (rect.height <= 160) {
                  break;
                } else {
                  target = target.parentElement;
                }
              }

              const rect = target.getBoundingClientRect();
              if (rect.height <= 170 && rect.bottom >= window.innerHeight - 8) {
                target.style.setProperty('display', 'none', 'important');
              }
            }
          };

          let pending = 0;
          const scheduleHideCookieNotice = () => {
            window.clearTimeout(pending);
            pending = window.setTimeout(hideCookieNotice, 200);
          };

          hideCookieNotice();
          new MutationObserver(scheduleHideCookieNotice).observe(document.documentElement, {
            childList: true,
            subtree: true
          });
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}
