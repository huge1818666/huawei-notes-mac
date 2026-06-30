import Foundation
import Security

public protocol CookieVaultStorage {
    func loadData() throws -> Data?
    func saveData(_ data: Data) throws
    func deleteData() throws
}

public enum CookieVaultError: Error, Equatable {
    case unexpectedKeychainStatus(OSStatus)
}

public final class KeychainCookieVaultStorage: CookieVaultStorage {
    private let service: String
    private let account: String

    public init(
        service: String = CookieVault.service,
        account: String = CookieVault.account
    ) {
        self.service = service
        self.account = account
    }

    public func loadData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CookieVaultError.unexpectedKeychainStatus(status)
        }
        return result as? Data
    }

    public func saveData(_ data: Data) throws {
        var addQuery = baseQuery()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus != errSecDuplicateItem {
            throw CookieVaultError.unexpectedKeychainStatus(addStatus)
        }

        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw CookieVaultError.unexpectedKeychainStatus(updateStatus)
        }
    }

    public func deleteData() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CookieVaultError.unexpectedKeychainStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
    }
}

public final class FileCookieVaultStorage: CookieVaultStorage {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = FileCookieVaultStorage.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadData() throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    public func saveData(_ data: Data) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func deleteData() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    public static func defaultFileURL() -> URL {
        let supportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        return supportURL
            .appendingPathComponent("com.codex.huaweinotes", isDirectory: true)
            .appendingPathComponent("CookieVault.json")
    }
}

public final class ResilientCookieVaultStorage: CookieVaultStorage {
    private let primary: CookieVaultStorage
    private let fallback: CookieVaultStorage
    private let decoder = JSONDecoder()

    public init(
        primary: CookieVaultStorage = KeychainCookieVaultStorage(),
        fallback: CookieVaultStorage = FileCookieVaultStorage()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func loadData() throws -> Data? {
        let primaryData = try? primary.loadData()

        let fallbackData: Data?
        do {
            fallbackData = try fallback.loadData()
        } catch {
            if let primaryData {
                return primaryData
            }
            throw error
        }

        return preferredData(primary: primaryData, fallback: fallbackData)
    }

    public func saveData(_ data: Data) throws {
        do {
            try primary.saveData(data)
            try? fallback.deleteData()
        } catch {
            try fallback.saveData(data)
        }
    }

    public func deleteData() throws {
        var firstError: Error?

        do {
            try primary.deleteData()
        } catch {
            firstError = error
        }

        do {
            try fallback.deleteData()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func preferredData(primary: Data?, fallback: Data?) -> Data? {
        switch (primary, fallback) {
        case (nil, nil):
            return nil
        case let (primary?, nil):
            return primary
        case let (nil, fallback?):
            return fallback
        case let (primary?, fallback?):
            let primarySavedAt = savedAt(in: primary)
            let fallbackSavedAt = savedAt(in: fallback)

            switch (primarySavedAt, fallbackSavedAt) {
            case let (primaryDate?, fallbackDate?):
                return fallbackDate > primaryDate ? fallback : primary
            case (_?, nil):
                return primary
            case (nil, _?):
                return fallback
            case (nil, nil):
                return primary
            }
        }
    }

    private func savedAt(in data: Data) -> Date? {
        (try? decoder.decode(CookieVaultPayload.self, from: data))?.savedAt
    }
}

public final class CookieVault {
    public static let service = "com.codex.huaweinotes.cookie-vault"
    public static let account = "default"
    public static let sessionCookieLifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let allowedDomainSuffixes = ["huawei.com", "huaweicloud.com", "vmall.com"]

    private let storage: CookieVaultStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(storage: CookieVaultStorage = FileCookieVaultStorage()) {
        self.storage = storage
        encoder.outputFormatting = [.sortedKeys]
    }

    public func save(_ cookies: [HTTPCookie], now: Date = Date()) throws {
        let storedCookies = deduplicatedCookies(
            cookies.compactMap { cookie -> StoredCookie? in
                StoredCookie(cookie: cookie, capturedAt: now)
            }
            .filter { $0.isValid(at: now) }
        )

        guard !storedCookies.isEmpty else {
            try storage.deleteData()
            return
        }

        let payload = CookieVaultPayload(version: 1, savedAt: now, cookies: storedCookies)
        try storage.saveData(encoder.encode(payload))
    }

    public func restoreCookies(now: Date = Date()) throws -> [HTTPCookie] {
        guard let data = try storage.loadData() else {
            return []
        }

        let payload = try decoder.decode(CookieVaultPayload.self, from: data)
        return deduplicatedCookies(payload.cookies).compactMap { storedCookie in
            guard storedCookie.isValid(at: now) else { return nil }
            return storedCookie.makeCookie()
        }
    }

    public func delete() throws {
        try storage.deleteData()
    }

    public static func isAllowedCookieDomain(_ domain: String) -> Bool {
        let normalizedDomain = normalizeDomain(domain)
        return allowedDomainSuffixes.contains { suffix in
            normalizedDomain == suffix || normalizedDomain.hasSuffix(".\(suffix)")
        }
    }

    public static func normalizeDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func deduplicatedCookies(_ cookies: [StoredCookie]) -> [StoredCookie] {
        var cookiesByKey: [StoredCookieKey: StoredCookie] = [:]
        for cookie in cookies {
            if let existing = cookiesByKey[cookie.key] {
                if cookie.isMorePersistent(than: existing) {
                    cookiesByKey[cookie.key] = cookie
                }
            } else {
                cookiesByKey[cookie.key] = cookie
            }
        }

        return cookiesByKey.values.sorted { left, right in
            if left.normalizedDomain != right.normalizedDomain {
                return left.normalizedDomain < right.normalizedDomain
            }
            if left.domain != right.domain { return left.domain < right.domain }
            if left.path != right.path { return left.path < right.path }
            return left.name < right.name
        }
    }
}

private struct StoredCookieKey: Hashable {
    let domain: String
    let path: String
    let name: String
}

public struct CookieVaultPayload: Codable, Equatable {
    public let version: Int
    public let savedAt: Date
    public let cookies: [StoredCookie]

    public init(version: Int, savedAt: Date, cookies: [StoredCookie]) {
        self.version = version
        self.savedAt = savedAt
        self.cookies = cookies
    }
}

public struct StoredCookie: Codable, Equatable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let capturedAt: Date
    public let isSecure: Bool
    public let isHTTPOnly: Bool
    public let sameSitePolicy: String?

    public init?(
        cookie: HTTPCookie,
        capturedAt: Date
    ) {
        guard CookieVault.isAllowedCookieDomain(cookie.domain) else {
            return nil
        }

        name = cookie.name
        value = cookie.value
        domain = cookie.domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        path = cookie.path.isEmpty ? "/" : cookie.path
        expiresAt = cookie.expiresDate
        self.capturedAt = capturedAt
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        sameSitePolicy = cookie.properties?[HTTPCookiePropertyKey("SameSite")] as? String
    }

    public func isValid(at date: Date) -> Bool {
        guard !name.isEmpty, CookieVault.isAllowedCookieDomain(domain) else {
            return false
        }

        if let expiresAt {
            return expiresAt > date
        }

        return capturedAt.addingTimeInterval(CookieVault.sessionCookieLifetime) > date
    }

    public func makeCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]

        if let expiresAt {
            properties[.expires] = expiresAt
        }
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let sameSitePolicy {
            properties[HTTPCookiePropertyKey("SameSite")] = sameSitePolicy
        }

        return HTTPCookie(properties: properties)
    }

    var normalizedDomain: String {
        CookieVault.normalizeDomain(domain)
    }

    fileprivate var key: StoredCookieKey {
        StoredCookieKey(domain: domain, path: path, name: name)
    }

    fileprivate func isMorePersistent(than other: StoredCookie) -> Bool {
        switch (expiresAt, other.expiresAt) {
        case let (left?, right?) where left != right:
            return left > right
        case let (left?, right?) where left == right:
            return capturedAt > other.capturedAt
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return capturedAt > other.capturedAt
        default:
            return false
        }
    }
}
