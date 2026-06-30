import Foundation

public struct HeartbeatResult: Equatable {
    public let statusCode: Int?
    public let finalURLString: String?
    public let redirectLocation: String?
    public let errorDescription: String?

    public init(
        statusCode: Int?,
        finalURLString: String?,
        redirectLocation: String?,
        errorDescription: String?
    ) {
        self.statusCode = statusCode
        self.finalURLString = finalURLString
        self.redirectLocation = redirectLocation
        self.errorDescription = errorDescription
    }

    public var isHTTPRedirect: Bool {
        guard let statusCode else { return false }
        return (300..<400).contains(statusCode)
    }

    public var summary: String {
        [
            statusCode.map { "status=\($0)" },
            finalURLString.map { "url=\($0)" },
            redirectLocation.map { "location=\($0)" },
            errorDescription.map { "error=\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

@MainActor
public final class HeartbeatClient {
    public static let sessionRefreshURL = URL(string: "https://cloud.huawei.com/refreshLoginStatus")!

    private let sessionRefreshURL: URL
    private let refererURL: String

    public init(
        sessionRefreshURL: URL = HeartbeatClient.sessionRefreshURL,
        refererURL: String = "https://cloud.huawei.com/home"
    ) {
        self.sessionRefreshURL = sessionRefreshURL
        self.refererURL = refererURL
    }

    public func check(cookies: [HTTPCookie], userAgent: String?) async -> HeartbeatResult {
        var request = URLRequest(
            url: sessionRefreshURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
        )
        request.httpMethod = "POST"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("https://cloud.huawei.com", forHTTPHeaderField: "Origin")
        request.setValue(refererURL, forHTTPHeaderField: "Referer")
        request.setValue(userAgent ?? Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        let traceID = Self.makeTraceID()
        request.setValue(traceID, forHTTPHeaderField: "x-hw-trace-id")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["traceId": traceID])

        let matchingCookies = Self.cookies(cookies, matching: sessionRefreshURL)
        if !matchingCookies.isEmpty {
            let fields = HTTPCookie.requestHeaderFields(with: matchingCookies)
            if let cookieHeader = fields["Cookie"] {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }

        let delegate = RedirectBlocker()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return HeartbeatResult(
                    statusCode: nil,
                    finalURLString: nil,
                    redirectLocation: nil,
                    errorDescription: "non-http-response"
                )
            }

            return HeartbeatResult(
                statusCode: response.statusCode,
                finalURLString: response.url?.absoluteString,
                redirectLocation: response.value(forHTTPHeaderField: "Location"),
                errorDescription: nil
            )
        } catch {
            return HeartbeatResult(
                statusCode: nil,
                finalURLString: sessionRefreshURL.absoluteString,
                redirectLocation: nil,
                errorDescription: String(describing: error)
            )
        }
    }

    private static func cookies(_ cookies: [HTTPCookie], matching url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"

        return cookies.filter { cookie in
            guard !cookie.isSecure || isHTTPS else { return false }

            let rawDomain = cookie.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedDomain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches: Bool
            if rawDomain.hasPrefix(".") {
                domainMatches = host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)")
            } else {
                domainMatches = host == normalizedDomain
            }

            guard domainMatches else { return false }

            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return requestPath.hasPrefix(cookiePath)
        }
        .sorted { left, right in
            if left.path.count != right.path.count {
                return left.path.count > right.path.count
            }
            return left.name < right.name
        }
    }

    private static func makeTraceID() -> String {
        "00001-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    }

    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
