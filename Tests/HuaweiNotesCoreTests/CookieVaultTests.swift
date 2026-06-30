import Foundation
import HuaweiNotesCore
import Security
import Testing

@Suite("CookieVault")
struct CookieVaultTests {
    @Test
    func testAllowedDomainsUseStrictSuffixMatching() {
        #expect(CookieVault.isAllowedCookieDomain("huawei.com"))
        #expect(CookieVault.isAllowedCookieDomain(".cloud.huawei.com"))
        #expect(CookieVault.isAllowedCookieDomain("id1.huaweicloud.com"))
        #expect(CookieVault.isAllowedCookieDomain("shop.vmall.com"))

        #expect(!CookieVault.isAllowedCookieDomain("evilhuawei.com"))
        #expect(!CookieVault.isAllowedCookieDomain("huawei.com.example.com"))
        #expect(!CookieVault.isAllowedCookieDomain("example.com"))
    }

    @Test
    func testSaveAndRestoreFiltersAllowedCookiesOnly() throws {
        let storage = MemoryCookieVaultStorage()
        let vault = CookieVault(storage: storage)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let allowed = try makeCookie(
            name: "session",
            value: "secret",
            domain: ".cloud.huawei.com",
            expires: now.addingTimeInterval(3600),
            isSecure: true,
            isHTTPOnly: true
        )
        let rejected = try makeCookie(
            name: "tracking",
            value: "ignored",
            domain: "example.com",
            expires: now.addingTimeInterval(3600)
        )

        try vault.save([allowed, rejected], now: now)
        let restored = try vault.restoreCookies(now: now.addingTimeInterval(60))

        #expect(restored.count == 1)
        let cookie = try #require(restored.first)
        #expect(cookie.name == "session")
        #expect(cookie.value == "secret")
        #expect(cookie.domain == ".cloud.huawei.com")
        #expect(cookie.path == "/")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
    }

    @Test
    func testSavePreservesDomainCookieAndHostOnlyCookieSeparately() throws {
        let storage = MemoryCookieVaultStorage()
        let vault = CookieVault(storage: storage)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let domainCookie = try makeCookie(
            name: "session",
            value: "domain",
            domain: ".cloud.huawei.com",
            expires: now.addingTimeInterval(3600)
        )
        let hostCookie = try makeCookie(
            name: "session",
            value: "host",
            domain: "cloud.huawei.com",
            expires: now.addingTimeInterval(3600)
        )

        try vault.save([domainCookie, hostCookie], now: now)
        let restored = try vault.restoreCookies(now: now.addingTimeInterval(60))

        #expect(restored.count == 2)
        #expect(restored.contains { $0.domain == ".cloud.huawei.com" && $0.value == "domain" })
        #expect(restored.contains { $0.domain == "cloud.huawei.com" && $0.value == "host" })
    }

    @Test
    func testSaveDeduplicatesExactCookieKeyUsingMostPersistentCookie() throws {
        let storage = MemoryCookieVaultStorage()
        let vault = CookieVault(storage: storage)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let stale = try makeCookie(
            name: "session",
            value: "stale",
            domain: "cloud.huawei.com",
            expires: now.addingTimeInterval(3600)
        )
        let fresh = try makeCookie(
            name: "session",
            value: "fresh",
            domain: "cloud.huawei.com",
            expires: now.addingTimeInterval(7200)
        )

        try vault.save([stale, fresh], now: now)
        let restored = try vault.restoreCookies(now: now.addingTimeInterval(60))

        #expect(restored.count == 1)
        #expect(restored.first?.value == "fresh")
    }

    @Test
    func testSessionCookieExpiresAfterThirtyDays() throws {
        let storage = MemoryCookieVaultStorage()
        let vault = CookieVault(storage: storage)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cookie = try makeCookie(
            name: "session",
            value: "secret",
            domain: "cloud.huawei.com",
            expires: nil
        )

        try vault.save([cookie], now: now)

        let beforeExpiry = try vault.restoreCookies(
            now: now.addingTimeInterval(CookieVault.sessionCookieLifetime - 1)
        )
        #expect(beforeExpiry.count == 1)

        let afterExpiry = try vault.restoreCookies(
            now: now.addingTimeInterval(CookieVault.sessionCookieLifetime + 1)
        )
        #expect(afterExpiry.isEmpty)
    }

    @Test
    func testExpiredPersistentCookieIsNotRestored() throws {
        let storage = MemoryCookieVaultStorage()
        let vault = CookieVault(storage: storage)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cookie = try makeCookie(
            name: "expired",
            value: "secret",
            domain: "cloud.huawei.com",
            expires: now.addingTimeInterval(60)
        )

        try vault.save([cookie], now: now)
        let restored = try vault.restoreCookies(now: now.addingTimeInterval(120))

        #expect(restored.isEmpty)
    }

    @Test
    func testSavingNoAllowedCookiesDeletesVault() throws {
        let storage = MemoryCookieVaultStorage()
        let vault = CookieVault(storage: storage)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let allowed = try makeCookie(
            name: "session",
            value: "secret",
            domain: "cloud.huawei.com",
            expires: now.addingTimeInterval(3600)
        )
        let rejected = try makeCookie(
            name: "other",
            value: "ignored",
            domain: "example.com",
            expires: now.addingTimeInterval(3600)
        )

        try vault.save([allowed], now: now)
        #expect(storage.data != nil)

        try vault.save([rejected], now: now)
        #expect(storage.data == nil)
    }

    @Test
    func testResilientStorageLoadsFromFallbackWhenPrimaryFails() throws {
        let fallback = MemoryCookieVaultStorage()
        let expected = Data("fallback".utf8)
        fallback.data = expected

        let storage = ResilientCookieVaultStorage(
            primary: FailingCookieVaultStorage(),
            fallback: fallback
        )

        let loaded = try storage.loadData()
        #expect(loaded == expected)
    }

    @Test
    func testResilientStorageLoadsNewerFallbackPayload() throws {
        let primary = MemoryCookieVaultStorage()
        let fallback = MemoryCookieVaultStorage()
        let older = try makePayloadData(savedAt: Date(timeIntervalSince1970: 1_000))
        let newer = try makePayloadData(savedAt: Date(timeIntervalSince1970: 2_000))
        primary.data = older
        fallback.data = newer

        let storage = ResilientCookieVaultStorage(primary: primary, fallback: fallback)
        let loaded = try storage.loadData()

        #expect(loaded == newer)
    }

    @Test
    func testResilientStorageKeepsNewerPrimaryPayload() throws {
        let primary = MemoryCookieVaultStorage()
        let fallback = MemoryCookieVaultStorage()
        let newer = try makePayloadData(savedAt: Date(timeIntervalSince1970: 2_000))
        let older = try makePayloadData(savedAt: Date(timeIntervalSince1970: 1_000))
        primary.data = newer
        fallback.data = older

        let storage = ResilientCookieVaultStorage(primary: primary, fallback: fallback)
        let loaded = try storage.loadData()

        #expect(loaded == newer)
    }

    @Test
    func testResilientStorageSavesToFallbackWhenPrimaryFails() throws {
        let fallback = MemoryCookieVaultStorage()
        let storage = ResilientCookieVaultStorage(
            primary: FailingCookieVaultStorage(),
            fallback: fallback
        )
        let expected = Data("fallback".utf8)

        try storage.saveData(expected)

        #expect(fallback.data == expected)
    }

    private func makeCookie(
        name: String,
        value: String,
        domain: String,
        expires: Date?,
        path: String = "/",
        isSecure: Bool = false,
        isHTTPOnly: Bool = false
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]

        if let expires {
            properties[.expires] = expires
        }
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        guard let cookie = HTTPCookie(properties: properties) else {
            throw CookieFactoryError.invalidCookie
        }
        return cookie
    }

    private func makePayloadData(savedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = CookieVaultPayload(version: 1, savedAt: savedAt, cookies: [])
        return try encoder.encode(payload)
    }
}

private enum CookieFactoryError: Error {
    case invalidCookie
}

private final class MemoryCookieVaultStorage: CookieVaultStorage {
    var data: Data?

    func loadData() throws -> Data? {
        data
    }

    func saveData(_ data: Data) throws {
        self.data = data
    }

    func deleteData() throws {
        data = nil
    }
}

private final class FailingCookieVaultStorage: CookieVaultStorage {
    func loadData() throws -> Data? {
        throw CookieVaultError.unexpectedKeychainStatus(errSecInteractionNotAllowed)
    }

    func saveData(_ data: Data) throws {
        throw CookieVaultError.unexpectedKeychainStatus(errSecInteractionNotAllowed)
    }

    func deleteData() throws {
        throw CookieVaultError.unexpectedKeychainStatus(errSecInteractionNotAllowed)
    }
}
