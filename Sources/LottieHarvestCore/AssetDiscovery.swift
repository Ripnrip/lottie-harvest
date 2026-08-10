import Foundation

/// Pure discovery + classification core.
///
/// Everything here is a total function over plain `String`/`URL` input — no I/O,
/// no globals — so it composes with *any* discovery front-end: a headless-Chrome
/// DOM dump, a browsermcp-saved page, a raw API JSON blob, or a hand-pasted URL
/// list. The CDN downloader then pulls the classified URLs directly (the asset
/// CDN is open; only the browse layer is Cloudflare-walled).
public enum AssetDiscovery {

    // MARK: Public entry points

    /// Extract every Lottie asset URL embedded in an arbitrary HTML/JSON blob.
    public static func discoverAssets(in text: String) -> [LottieAsset] {
        var found: [LottieAsset] = []
        for raw in allRawMatches(in: text) {
            if let asset = classify(rawUrl: raw) { found.append(asset) }
        }
        return found
    }

    /// Extract LottieFiles animation-page links (`/animation/<slug>_<id>`)
    /// so a crawler can recurse for per-animation metadata.
    public static func discoverAnimationPages(in text: String, base: URL? = nil) -> [URL] {
        let pattern = #"/animation/[A-Za-z0-9_-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let urls = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        let prefix: String
        if let base {
            prefix = base.absoluteString.hasSuffix("/")
                ? String(base.absoluteString.dropLast())
                : base.absoluteString
        } else {
            prefix = "https://lottiefiles.com"
        }
        return Set(urls).compactMap { URL(string: prefix + $0) }
    }

    /// Dedupe by animation identity, keeping the richest kind for each id
    /// (dotLottie > json > thumbnail).
    public static func dedupe(_ assets: [LottieAsset]) -> [LottieAsset] {
        var best: [String: LottieAsset] = [:]
        func rank(_ k: AssetKind) -> Int {
            switch k { case .dotLottie: 2; case .json: 1; case .thumbnail: 0 }
        }
        for a in assets {
            if let existing = best[a.animationId] {
                if rank(a.kind) > rank(existing.kind) { best[a.animationId] = a }
            } else {
                best[a.animationId] = a
            }
        }
        return best.values.sorted { $0.animationId < $1.animationId }
    }

    /// Classify a single raw URL string (protocol-relative `//…` allowed).
    /// Shared by both the regex scraper and the direct URL-list front-end.
    public static func classify(rawUrl raw: String) -> LottieAsset? {
        let normalized: String
        if raw.hasPrefix("//") {
            normalized = "https:" + raw
        } else if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            normalized = raw
        } else if raw.hasPrefix("/") {
            normalized = "https://lottiefiles.com" + raw
        } else {
            normalized = "https://" + raw
        }
        guard let url = URL(string: normalized) else { return nil }
        return classify(url: url)
    }

    /// Classify a structured URL into a `LottieAsset`, or `nil` if it is not a
    /// recognized Lottie asset URL.
    public static func classify(url: URL) -> LottieAsset? {
        let host = (url.host ?? "").lowercased()
        let path = url.path

        // assets-v2.lottiefiles.com/a/<uuid>/<stem>.<ext>
        if host == "assets-v2.lottiefiles.com" {
            let parts = path.split(separator: "/").map(String.init) // ["a", uuid, "stem.ext"]
            guard parts.count >= 3, parts[0] == "a" else { return nil }
            let uuid = parts[1]
            let file = parts[2]
            guard uuid.count >= 32 else { return nil }
            guard let (stem, kind) = splitExt(file) else { return nil }
            return LottieAsset(
                url: url,
                source: .lottiefilesV2,
                kind: kind,
                animationId: uuid,
                stem: stem
            )
        }

        // assets{N}.lottiefiles.com/packages/lf<id>.<ext>
        if host.hasPrefix("assets") && host.hasSuffix(".lottiefiles.com") && path.contains("/packages/") {
            let file = (path as NSString).lastPathComponent
            guard let (stem, kind) = splitExt(file), kind != .thumbnail else { return nil }
            return LottieAsset(
                url: url,
                source: .lottiefilesPackages,
                kind: kind,
                animationId: "packages/\(stem)",
                stem: stem
            )
        }

        // lottie.host/<uuid>/<name>.<ext>
        if host == "lottie.host" {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, parts[0].count >= 32 else { return nil }
            let uuid = parts[0]
            let file = parts[1]
            guard let (stem, kind) = splitExt(file), kind != .thumbnail else { return nil }
            return LottieAsset(
                url: url,
                source: .lottieHost,
                kind: kind,
                animationId: uuid,
                stem: stem
            )
        }

        // cdnl.iconscout.com/lottie/<...>.<ext>
        if host == "cdnl.iconscout.com" && path.contains("/lottie/") {
            let file = (path as NSString).lastPathComponent
            guard let (stem, kind) = splitExt(file) else { return nil }
            return LottieAsset(
                url: url,
                source: .iconscout,
                kind: kind,
                animationId: "iconscout/\(stem)",
                stem: stem
            )
        }

        return nil
    }

    // MARK: Internals

    private static func splitExt(_ filename: String) -> (stem: String, AssetKind)? {
        let lower = (filename as NSString).pathExtension.lowercased()
        let stem = (filename as NSString).deletingPathExtension
        switch lower {
        case "lottie": return (stem, .dotLottie)
        case "json":   return (stem, .json)
        case "png", "jpg", "jpeg", "webp", "gif":
            return (stem, .thumbnail)
        default: return nil
        }
    }

    private static func allRawMatches(in text: String) -> [String] {
        let patterns: [String] = [
            // protocol-relative or absolute v2 / packages / host / iconscout
            #"//?assets-v2\.lottiefiles\.com/a/[0-9A-Fa-f-]{36}/[A-Za-z0-9_-]+\.[A-Za-z0-9]+"#,
            #"https?://assets-v2\.lottiefiles\.com/a/[0-9A-Fa-f-]{36}/[A-Za-z0-9_-]+\.[A-Za-z0-9]+"#,
            #"//?assets[0-9]*\.lottiefiles\.com/packages/[A-Za-z0-9_]+\.[A-Za-z0-9]+"#,
            #"https?://assets[0-9]*\.lottiefiles\.com/packages/[A-Za-z0-9_]+\.[A-Za-z0-9]+"#,
            #"//?lottie\.host/[0-9A-Fa-f-]{36}/[A-Za-z0-9_.-]+\.[A-Za-z0-9]+"#,
            #"https?://lottie\.host/[0-9A-Fa-f-]{36}/[A-Za-z0-9_.-]+\.[A-Za-z0-9]+"#,
            #"https?://cdnl\.iconscout\.com/lottie/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+"#,
        ]
        var seen = Set<String>()
        var out: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range)
                // Canonicalize to an absolute https URL so the protocol-relative
                // pattern and the absolute pattern don't double-count the same ref.
                let cleaned: String
                if raw.hasPrefix("https:////") {
                    cleaned = "https://" + raw.dropFirst(8)
                } else if raw.hasPrefix("//") {
                    cleaned = "https:" + raw
                } else {
                    cleaned = raw
                }
                if seen.insert(cleaned).inserted { out.append(cleaned) }
            }
        }
        return out
    }
}
