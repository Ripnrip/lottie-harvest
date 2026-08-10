import Foundation
import os

/// A strategy for turning a page URL into its rendered HTML/JSON text.
///
/// The harvester is fetcher-agnostic on purpose: `StaticFetcher` handles raw
/// CDN/API/JSON (no JS), while `HeadlessChromeFetcher` renders JS and bypasses
/// soft Cloudflare bot checks. Anything browsermcp-saved is fed in directly as
/// a URL/asset list, so the harvester never depends on a specific browser tool.
public protocol PageFetcher: Sendable {
    func fetch(_ url: URL) async throws -> String
}

/// Plain `URLSession` fetch with a browser identity. Use for API JSON, raw
/// asset probes, or any page that does not require JavaScript.
public struct StaticFetcher: PageFetcher {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = [
            "User-Agent": Downloader.browserUA,
            "Accept": "text/html,application/json,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        self.session = URLSession(configuration: config)
    }

    public func fetch(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "StaticFetcher", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.absoluteString)"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

#if os(macOS) || os(Linux)
/// Renders a page with headless Google Chrome (`--headless=new --dump-dom`).
///
/// Best-effort against Cloudflare: many LottieFiles gallery pages render fine
/// headlessly, but category pages sometimes hit the "Just a moment…" challenge.
/// We detect that and retry with backoff; on persistent failure the caller
/// should fall back to a real browser session (browsermcp) feeding a URL list.
public struct HeadlessChromeFetcher: PageFetcher {
    public let chromePath: String
    public let virtualTimeBudgetMs: Int
    public let retries: Int

    public init(chromePath: String? = nil, budgetMs: Int = 12000, retries: Int = 2) {
        self.chromePath = chromePath ?? HeadlessChromeFetcher.defaultChromePath()
        self.virtualTimeBudgetMs = budgetMs
        self.retries = retries
    }

    public func fetch(_ url: URL) async throws -> String {
        var attempt = 0
        var backoff = UInt64(1_500_000_000) // 1.5s
        while true {
            attempt += 1
            let html = try await render(url: url)
            if !Self.looksCloudflareChallenged(html) {
                return html
            }
            Logger.discovery.warning("🌫️ Cloudflare interstitial on attempt \(attempt) for \(url.absoluteString, privacy: .public)")
            if attempt > retries {
                return html // return whatever we have; discovery may still find 0
            }
            try? await Task.sleep(nanoseconds: backoff)
            backoff &*= 2
        }
    }

    // MARK: Internals

    private func render(url: URL) async throws -> String {
        let args = [
            "--headless=new", "--disable-gpu", "--no-sandbox",
            "--no-first-run", "--no-default-browser-check",
            "--user-agent=\(Downloader.browserUA)",
            "--virtual-time-budget=\(virtualTimeBudgetMs)",
            "--dump-dom", url.absoluteString,
        ]
        return try await Task.detached(priority: .userInitiated) { [chromePath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: chromePath)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe() // silence noise
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    static func looksCloudflareChallenged(_ html: String) -> Bool {
        let title = html.range(of: "<title>[^<]*</title>", options: .regularExpression)
            .map { String(html[$0]).lowercased() } ?? ""
        if title.contains("just a moment") { return true }
        let hints = ["cf-challenge", "cf_chl_opt", "challenge-platform", "cdn-cgi/challenge"]
        return hints.contains { html.contains($0) }
    }

    public static func defaultChromePath() -> String {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/usr/bin/google-chrome", "/usr/bin/chromium",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    }
}
#endif
