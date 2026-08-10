import ArgumentParser
import Foundation
import LottieHarvestCore

extension PullFormat: ExpressibleByArgument {
    public init?(argument: String) { self.init(rawValue: argument) }
    public var defaultValueDescription: String { rawValue }
}

extension GraphQLSearcher.Collection: ExpressibleByArgument {
    public init?(argument: String) { self.init(rawValue: argument) }
}

@main
struct LottieHarvestCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lottie-harvest",
        abstract: "Bulk-scrape & download Lottie animations (dotLottie / JSON) from the open Lottie asset CDN.",
        version: "1.0.0",
        subcommands: [Search.self, Browse.self, Discover.self, Pull.self, Harvest.self, Validate.self, CatalogCommand.self, Gallery.self]
    )
}

// MARK: - Shared options

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Output directory for downloaded assets.")
    var out: String = "./lottie-assets"

    @Option(name: .long, help: "Catalog JSONL path (default: <out>/catalog.jsonl).")
    var catalog: String?

    @Option(name: .long, help: "Max concurrent downloads.")
    var concurrency: Int = 8

    @Option(name: .long, help: "Format to pull: dotLottie | json | both.")
    var format: PullFormat = .dotLottie

    @Flag(name: .long, help: "Also download PNG thumbnails (v2/host assets only).")
    var thumbs = false

    @Option(name: .long, help: "Discovery fetcher: chrome | static.")
    var fetcher: String = "chrome"

    @Option(name: .long, help: "Path to Google Chrome (for the chrome fetcher).")
    var chrome: String?

    func catalogURL() -> URL {
        if let catalog { return URL(fileURLWithPath: catalog) }
        return URL(fileURLWithPath: out, isDirectory: true)
            .appendingPathComponent("catalog.jsonl")
    }

    func rootURL() -> URL { URL(fileURLWithPath: out, isDirectory: true) }

    func makeFetcher() -> (any PageFetcher)? {
        switch fetcher.lowercased() {
        case "static": return StaticFetcher()
        case "chrome": return HeadlessChromeFetcher(chromePath: chrome)
        default:       return nil
        }
    }

    func harvesterOptions() -> HarvesterOptions {
        HarvesterOptions(root: rootURL(), concurrency: concurrency,
                         pullFormat: format, includeThumbnails: thumbs)
    }
}

// MARK: - search (GraphQL; Cloudflare-free)

extension LottieHarvestCLI {
    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search LottieFiles by keyword via the public GraphQL API and download.")

        @OptionGroup var globals: GlobalOptions

        @Flag(name: .long, help: "Print discovered URLs without downloading.")
        var dryRun = false

        @Option(name: .long, help: "Max animations to return (GraphQL pages in batches of 50).")
        var limit: Int?

        @Argument(help: "Search query, e.g. 'apple'.")
        var query: String

        func run() async throws {
            let animations = await GraphQLSearcher().search(query, limit: limit)
            print("🔎 search('\(query)') → \(animations.count) animations")
            if dryRun {
                for a in animations { print("   \(describe(a))") }
                return
            }
            try FileManager.default.createDirectory(at: globals.rootURL(), withIntermediateDirectories: true)
            let catalog = await Catalog(fileURL: globals.catalogURL())
            let report = try await Harvester.pull(animations, options: globals.harvesterOptions(), into: catalog)
            print(report.describe())
        }
    }
}

// MARK: - browse (GraphQL collections)

extension LottieHarvestCLI {
    struct Browse: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Browse a LottieFiles collection (popular|recent|featured|curated) and download.")

        @OptionGroup var globals: GlobalOptions

        @Flag(name: .long, help: "Print discovered URLs without downloading.")
        var dryRun = false

        @Option(name: .long, help: "Max animations to return.")
        var limit: Int?

        @Option(name: .long, help: "Category (required for 'curated', e.g. loading, success, arrow).")
        var category: String?

        @Argument(help: "Collection: popular | recent | featured | curated.")
        var collection: GraphQLSearcher.Collection

        func run() async throws {
            if collection == .curated, category == nil {
                throw ValidationError("'curated' requires --category <slug>.")
            }
            let animations = await GraphQLSearcher().browse(collection, category: category, limit: limit)
            print("🔎 browse(\(collection)\(category.map { "/\($0)" } ?? "")) → \(animations.count) animations")
            if dryRun {
                for a in animations { print("   \(describe(a))") }
                return
            }
            try FileManager.default.createDirectory(at: globals.rootURL(), withIntermediateDirectories: true)
            let catalog = await Catalog(fileURL: globals.catalogURL())
            let report = try await Harvester.pull(animations, options: globals.harvesterOptions(), into: catalog)
            print(report.describe())
        }
    }
}

// MARK: - discover

extension LottieHarvestCLI {
    struct Discover: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Fetch seed pages and print discovered asset URLs (no download).")

        @OptionGroup var globals: GlobalOptions

        @Flag(name: .long, help: "Use built-in LottieFiles free-animation category seeds.")
        var categories = false

        @Option(name: .long, help: "Save discovered URLs (one per line) to this file.")
        var save: String?

        @Argument(help: "Seed page URLs (gallery / animation / category pages).")
        var seeds: [String] = []

        func run() async throws {
            guard let fetcher = globals.makeFetcher() else {
                throw ValidationError("Unknown --fetcher '\(globals.fetcher)'. Use chrome|static.")
            }
            let seedURLs = seeds.compactMap { URL(string: $0) }
            let pages = categories ? Self.categoryURLs() + seedURLs : seedURLs
            guard !pages.isEmpty else {
                throw ValidationError("Provide seed URLs or pass --categories.")
            }
            let animations = await Harvester.discover(from: pages, using: fetcher)
            print("Discovered \(animations.count) unique animations:")
            for a in animations { print("   \(describe(a))") }
            if let save {
                let payload = animations.compactMap { $0.variants.first?.url.absoluteString }
                    .joined(separator: "\n") + "\n"
                try payload.write(toFile: save, atomically: true, encoding: .utf8)
                print("→ saved \(animations.count) URLs to \(save)")
            }
        }

        static func categoryURLs() -> [URL] {
            let slugs = [
                "loading", "loader", "icon", "success", "arrow", "check", "circle",
                "confetti", "ui", "ux", "mobile", "search", "illustration", "line",
                "loop", "design", "interactivity", "theming", "animation", "lottie",
            ]
            var urls = slugs.compactMap { URL(string: "https://lottiefiles.com/free-animations/\($0)") }
            if let index = URL(string: "https://lottiefiles.com/free-animations") {
                urls.insert(index, at: 0)
            }
            return urls
        }
    }
}

// MARK: - pull

extension LottieHarvestCLI {
    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download a list of asset URLs (or --from a file). No page fetching.")

        @OptionGroup var globals: GlobalOptions

        @Option(name: .long, help: "Read asset URLs from a file (one per line). Feeds browsermcp output.")
        var from: String?

        @Argument(help: "Asset URLs (.lottie / .json / .png).")
        var urls: [String] = []

        func run() async throws {
            let assets = try resolveAssets()
            guard !assets.isEmpty else {
                throw ValidationError("No asset URLs. Pass URLs or --from <file>.")
            }
            try FileManager.default.createDirectory(at: globals.rootURL(), withIntermediateDirectories: true)
            let catalog = await Catalog(fileURL: globals.catalogURL())
            let report = try await Harvester.pull(Animation.grouping(assets), options: globals.harvesterOptions(), into: catalog)
            print(report.describe())
        }

        private func resolveAssets() throws -> [LottieAsset] {
            var lines = urls
            if let from {
                let text = try String(contentsOfFile: from, encoding: .utf8)
                lines += text.split(separator: "\n").map { String($0) }
            }
            return lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .compactMap { AssetDiscovery.classify(rawUrl: $0) }
        }
    }
}

// MARK: - harvest (discover + pull)

extension LottieHarvestCLI {
    struct Harvest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Discover from seed pages, then download in one shot.")

        @OptionGroup var globals: GlobalOptions

        @Flag(name: .long, help: "Use built-in LottieFiles category seeds in addition to <seeds>.")
        var categories = false

        @Option(name: .long, help: "Stop after this many unique animations.")
        var limit: Int?

        @Argument(help: "Seed page URLs.")
        var seeds: [String] = []

        func run() async throws {
            guard let fetcher = globals.makeFetcher() else {
                throw ValidationError("Unknown --fetcher '\(globals.fetcher)'. Use chrome|static.")
            }
            var pages = seeds.compactMap { URL(string: $0) }
            if categories { pages += LottieHarvestCLI.Discover.categoryURLs() }
            guard !pages.isEmpty else {
                throw ValidationError("Provide seed URLs or pass --categories.")
            }
            let assets = await Harvester.discover(from: pages, using: fetcher)
            let limited = limit.map { Array(assets.prefix($0)) } ?? assets
            try FileManager.default.createDirectory(at: globals.rootURL(), withIntermediateDirectories: true)
            let catalog = await Catalog(fileURL: globals.catalogURL())
            let report = try await Harvester.pull(limited, options: globals.harvesterOptions(), into: catalog)
            print(report.describe())
        }
    }
}

// MARK: - validate

extension LottieHarvestCLI {
    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-validate every stored asset under a directory.")

        @OptionGroup var globals: GlobalOptions

        func run() async throws {
            let root = globals.rootURL()
            var ok = 0, bad = 0
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
                print("Nothing to validate at \(root.path)")
                return
            }
            while let raw = enumerator.nextObject() {
                guard let url = raw as? URL else { continue }
                let ext = url.pathExtension.lowercased()
                guard ["lottie", "json", "png", "jpg", "gif", "webp"].contains(ext) else { continue }
                guard url.lastPathComponent != "catalog.jsonl",
                      let data = try? Data(contentsOf: url) else { continue }
                let kind: AssetKind = ext == "lottie" ? .dotLottie : (ext == "json" ? .json : .thumbnail)
                let result = LottieValidator.validate(data, kind: kind)
                if result.isValid { ok += 1 } else { bad += 1; print("⚠️  \(url.path) — \(result)") }
            }
            print("Validated: \(ok) ok, \(bad) broken.")
        }
    }
}

// MARK: - catalog

extension LottieHarvestCLI {
    struct CatalogCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "catalog",
            abstract: "Print the harvest catalog summary.")

        @OptionGroup var globals: GlobalOptions

        @Flag(name: .long, help: "Print every entry instead of just the summary.")
        var full = false

        func run() async throws {
            let catalog = await Catalog(fileURL: globals.catalogURL())
            let summary = await catalog.summary()
            print("Catalog: \(globals.catalogURL().path)")
            print("  total:    \(summary.total)")
            print("  ok:       \(summary.ok)")
            print("  skipped:  \(summary.skipped)")
            print("  invalid:  \(summary.invalid)")
            print("  failed:   \(summary.failed)")
            print("  bytes:    \(summary.bytes) (~\(summary.bytes / 1_000_000) MB)")
            if full {
                for e in await catalog.snapshot() {
                    var bits: [String] = ["[\(e.status.rawValue)]"]
                    if let n = e.meta?.name { bits.append(n) }
                    if let a = e.meta?.author { bits.append("by \(a)") }
                    if let d = e.meta?.downloads { bits.append("⬇\(d)") }
                    bits.append("— \(e.identity)  (\(e.summary))")
                    print("  " + bits.joined(separator: " "))
                }
            }
        }
    }
}

// MARK: - gallery

extension LottieHarvestCLI {
    struct Gallery: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build a self-contained HTML gallery from a catalog.")

        @OptionGroup var globals: GlobalOptions

        @Option(name: .long, help: "Gallery title.")
        var title: String = "Lottie Harvest Gallery"

        @Option(name: .long, help: "Output HTML path (default: <out>/index.html).")
        var output: String?

        func run() async throws {
            let catalog = await Catalog(fileURL: globals.catalogURL())
            let entries = await catalog.snapshot()
            let cards = GalleryBuilder.cards(from: entries)
            let html = GalleryBuilder.html(title: title, cards: cards)
            let outURL = URL(fileURLWithPath: output ?? "\(globals.out)/index.html")
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try html.write(to: outURL, atomically: true, encoding: .utf8)
            print("🖼️  gallery: \(cards.count) cards → \(outURL.path)")
        }
    }
}

// MARK: - Report formatting

/// One-line human description of a discovered animation (name + primary URL).
func describe(_ animation: Animation) -> String {
    let name = animation.meta?.name ?? animation.id
    let url = animation.variants.first(where: { $0.kind == .dotLottie })?.url
        ?? animation.variants.first(where: { $0.kind == .json })?.url
        ?? animation.variants.first?.url
    let author = animation.meta?.author.map { "  ·  \($0)" } ?? ""
    return "\(name)\(author)  →  \(url?.absoluteString ?? "")"
}

extension HarvestReport {
    func describe() -> String {
        """
        ✅ Harvest complete
           discovered: \(discovered)
           downloaded: \(downloaded)
           skipped:    \(skipped)
           invalid:    \(invalid)
           failed:     \(failed)
           bytes:      \(bytes) (~\(bytes / 1_000_000) MB)
        """
    }
}
