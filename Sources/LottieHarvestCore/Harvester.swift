import Foundation
import os

/// Pull-time options. Pure value; the harvester is a stateless enum of helpers.
public struct HarvesterOptions: Sendable {
    public var root: URL
    public var concurrency: Int
    public var pullFormat: PullFormat
    public var includeThumbnails: Bool

    public init(
        root: URL,
        concurrency: Int = 8,
        pullFormat: PullFormat = .dotLottie,
        includeThumbnails: Bool = false
    ) {
        self.root = root
        self.concurrency = concurrency
        self.pullFormat = pullFormat
        self.includeThumbnails = includeThumbnails
    }
}

public struct HarvestReport: Sendable, Equatable {
    public var discovered: Int = 0
    public var downloaded: Int = 0
    public var skipped: Int = 0
    public var invalid: Int = 0
    public var failed: Int = 0
    public var bytes: Int = 0

    public init() {}
}

/// One concrete thing to fetch and store. `storeAs` may differ from the
/// downloaded `asset.kind` when we extract a Lottie JSON out of a dotLottie.
public struct PullTarget: Sendable, Equatable {
    public let asset: LottieAsset
    public let storeAs: AssetKind
    public let alsoExtractJSON: Bool
    public let meta: AnimationMeta?

    public init(asset: LottieAsset, storeAs: AssetKind, alsoExtractJSON: Bool = false, meta: AnimationMeta? = nil) {
        self.asset = asset
        self.storeAs = storeAs
        self.alsoExtractJSON = alsoExtractJSON
        self.meta = meta
    }

    /// Kind-qualified identity for resumability (matches `CatalogEntry.identity`).
    public var identity: String { "\(storeAs.rawValue):\(asset.animationId)" }
}

/// Stateless orchestrator: discover → dedupe → download → validate → store → catalog.
public enum Harvester {

    /// Fetch each seed page (browser/front-end path) and collect deduped primaries.
    public static func discover(
        from pages: [URL],
        using fetcher: any PageFetcher
    ) async -> [Animation] {
        var found: [LottieAsset] = []
        for url in pages {
            Logger.discovery.info("🔎 discovering \(url.absoluteString, privacy: .public)")
            do {
                let html = try await fetcher.fetch(url)
                let assets = AssetDiscovery.discoverAssets(in: html)
                Logger.discovery.info("   found \(assets.count) raw asset refs")
                found.append(contentsOf: assets)
            } catch {
                Logger.discovery.error("❌ fetch failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let animations = Animation.grouping(found)
        Logger.lifecycle.info("🌱 discovery: \(animations.count) unique animations from \(pages.count) pages")
        return animations
    }

    /// Download, validate, and store the given asset variants per `options`.
    /// Variants are grouped by `animationId`; resumable via the catalog.
    public static func pull(
        _ animations: [Animation],
        options: HarvesterOptions,
        into catalog: Catalog
    ) async throws -> HarvestReport {
        let downloader = Downloader(concurrency: options.concurrency)
        let targets = animations.flatMap { animation in
            Self.targets(for: animation.variants,
                         format: options.pullFormat,
                         includeThumbnails: options.includeThumbnails,
                         meta: animation.meta)
        }
        let existing = await catalog.existingSuccessfulIds()
        let pending = targets.filter { !existing.contains($0.identity) }

        var report = HarvestReport()
        report.discovered = animations.count
        report.skipped = targets.count - pending.count
        guard !pending.isEmpty else {
            Logger.lifecycle.info("⏭️ nothing new to pull (\(report.skipped) already cataloged)")
            return report
        }
        Logger.lifecycle.info("🎯 pulling \(pending.count) targets (skipping \(report.skipped) existing)")

        var processed: [CatalogEntry] = []
        await withTaskGroup(of: [CatalogEntry].self) { group in
            for target in pending {
                group.addTask {
                    await processOne(target: target, downloader: downloader, root: options.root)
                }
            }
            for await entries in group {
                processed.append(contentsOf: entries)
                for entry in entries { await catalog.append(entry) }
            }
        }

        try await catalog.flush()

        for entry in processed {
            switch entry.status {
            case .ok:      report.downloaded += 1; report.bytes += entry.bytes
            case .skipped: report.skipped += 1
            case .invalid: report.invalid += 1
            case .failed:  report.failed += 1
            }
        }
        return report
    }

    // MARK: - Planning (pure)

    /// Choose concrete pull targets for one animation's variants. Public so it
    /// can be unit-tested directly.
    public static func targets(
        for variants: [LottieAsset],
        format: PullFormat,
        includeThumbnails: Bool,
        meta: AnimationMeta? = nil
    ) -> [PullTarget] {
        let dotLottie = variants.first { $0.kind == .dotLottie }
        let json = variants.first { $0.kind == .json }
        var out: [PullTarget] = []

        switch format {
        case .dotLottie:
            if let dotLottie {
                out.append(PullTarget(asset: dotLottie, storeAs: .dotLottie))
            } else if let json {
                out.append(PullTarget(asset: json, storeAs: .json))
            }
        case .json:
            if let json {
                out.append(PullTarget(asset: json, storeAs: .json))
            } else if let dotLottie {
                // No native JSON URL — extract the body out of the dotLottie zip.
                out.append(PullTarget(asset: dotLottie, storeAs: .json))
            }
        case .both:
            if let dotLottie, let json {
                out.append(PullTarget(asset: dotLottie, storeAs: .dotLottie))
                out.append(PullTarget(asset: json, storeAs: .json))
            } else if let dotLottie {
                // One download, two stored files (lottie + extracted json).
                out.append(PullTarget(asset: dotLottie, storeAs: .dotLottie, alsoExtractJSON: true))
            } else if let json {
                out.append(PullTarget(asset: json, storeAs: .json))
            }
        }

        if includeThumbnails, let thumb = variants.first(where: { $0.kind == .thumbnail }) {
            out.append(PullTarget(asset: thumb, storeAs: .thumbnail))
        }
        return out.map { PullTarget(asset: $0.asset, storeAs: $0.storeAs, alsoExtractJSON: $0.alsoExtractJSON, meta: meta) }
    }

    // MARK: - Processing

    static func processOne(
        target: PullTarget,
        downloader: Downloader,
        root: URL
    ) async -> [CatalogEntry] {
        let stamp = Date()
        do {
            let data = try await downloader.data(for: target.asset)
            return store(
                data: data, target: target, root: root, stamp: stamp
            )
        } catch {
            Logger.download.error("💥 \(target.identity, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return [CatalogEntry(
                animationId: target.asset.animationId, source: target.asset.source,
                kind: target.storeAs, url: target.asset.url, stem: target.asset.stem,
                savedPath: "", bytes: 0, summary: error.localizedDescription,
                status: .failed, meta: target.meta, downloadedAt: stamp
            )]
        }
    }

    /// Pure-ish storage step: validate the blob, then write it (and, if asked,
    /// an extracted JSON sibling). Synchronous I/O, but deterministic in shape.
    static func store(
        data: Data,
        target: PullTarget,
        root: URL,
        stamp: Date
    ) -> [CatalogEntry] {
        let primary = LottieValidator.validate(data, kind: target.asset.kind)

        // Case: dotLottie-only animation requested as JSON → extract body.
        if target.asset.kind == .dotLottie && target.storeAs == .json {
            return jsonEntries(fromDotLottie: data, source: target.asset, meta: target.meta, root: root, stamp: stamp)
        }

        switch primary {
        case .validLottieJSON(let spec):
            let path = (try? Storage.write(data, for: target.asset.withKind(target.storeAs), root: root))?.path ?? ""
            let summary = "json v\(spec.version) \(Int(spec.width))×\(Int(spec.height)) \(spec.layerCount)L @\(Int(spec.frameRate))fps"
            Logger.validate.info("✅ \(target.identity, privacy: .public) — \(summary, privacy: .public)")
            return [entry(target: target, savedPath: path, bytes: data.count, summary: summary, status: .ok, stamp: stamp)]
        case .validDotLottie:
            var entries: [CatalogEntry] = []
            let rawPath = (try? Storage.write(data, for: target.asset, root: root))?.path ?? ""
            let contents = try? Storage.extractDotLottie(data)
            let count = contents?.animationCount ?? 0
            let summary = "dotlottie · \(count) animation\(count == 1 ? "" : "s")"
            entries.append(entry(target: PullTarget(asset: target.asset, storeAs: .dotLottie, meta: target.meta), savedPath: rawPath, bytes: data.count, summary: summary, status: .ok, stamp: stamp))
            Logger.validate.info("✅ dotLottie:\(target.asset.animationId, privacy: .public) — \(summary, privacy: .public)")
            if target.alsoExtractJSON, let jsonData = contents?.primaryAnimationJSON {
                entries.append(contentsOf: writeJSON(jsonData, source: target.asset, meta: target.meta, root: root, stamp: stamp))
            }
            return entries
        case .validImage:
            let path = (try? Storage.write(data, for: target.asset, root: root))?.path ?? ""
            Logger.validate.info("🖼️ \(target.identity, privacy: .public) — image")
            return [entry(target: target, savedPath: path, bytes: data.count, summary: "thumbnail", status: .ok, stamp: stamp)]
        case .invalid(let reason):
            Logger.validate.error("⚠️ invalid \(target.identity, privacy: .public): \(reason, privacy: .public)")
            return [entry(target: target, savedPath: "", bytes: data.count, summary: reason, status: .invalid, stamp: stamp)]
        }
    }

    /// Extract the inner Lottie JSON from a dotLottie zip and store it as `.json`
    /// (used for `--format json` on a dotLottie-only animation).
    static func jsonEntries(
        fromDotLottie data: Data,
        source: LottieAsset,
        meta: AnimationMeta?,
        root: URL,
        stamp: Date
    ) -> [CatalogEntry] {
        if case .invalid(let reason) = LottieValidator.validateDotLottie(data) {
            return [badEntry(source: source, kind: .json, bytes: data.count, summary: reason, status: .invalid, meta: meta, stamp: stamp)]
        }
        guard let jsonData = (try? Storage.extractDotLottie(data))?.primaryAnimationJSON else {
            return [badEntry(source: source, kind: .json, bytes: data.count, summary: "no inner animation json", status: .invalid, meta: meta, stamp: stamp)]
        }
        return writeJSON(jsonData, source: source, meta: meta, root: root, stamp: stamp)
    }

    /// Write a Lottie JSON blob (native or extracted) and build its catalog entry.
    static func writeJSON(_ jsonData: Data, source: LottieAsset, meta: AnimationMeta?, root: URL, stamp: Date) -> [CatalogEntry] {
        let path = (try? Storage.write(jsonData, for: source.withKind(.json), root: root))?.path ?? ""
        let summary: String
        if case .validLottieJSON(let spec) = LottieValidator.validateJSON(jsonData) {
            summary = "json v\(spec.version) (extracted) \(Int(spec.width))×\(Int(spec.height))"
        } else {
            summary = "json (extracted)"
        }
        Logger.validate.info("✅ json:\(source.animationId, privacy: .public) — extracted from dotLottie")
        let target = PullTarget(asset: source.withKind(.json), storeAs: .json, meta: meta)
        return [entry(target: target, savedPath: path, bytes: jsonData.count, summary: summary, status: .ok, stamp: stamp)]
    }

    private static func badEntry(
        source: LottieAsset, kind: AssetKind, bytes: Int,
        summary: String, status: CatalogEntry.Status, meta: AnimationMeta?, stamp: Date
    ) -> CatalogEntry {
        CatalogEntry(animationId: source.animationId, source: source.source,
                     kind: kind, url: source.url, stem: source.stem,
                     savedPath: "", bytes: bytes, summary: summary,
                     status: status, meta: meta, downloadedAt: stamp)
    }

    private static func entry(
        target: PullTarget, savedPath: String, bytes: Int,
        summary: String, status: CatalogEntry.Status, stamp: Date
    ) -> CatalogEntry {
        CatalogEntry(
            animationId: target.asset.animationId, source: target.asset.source,
            kind: target.storeAs, url: target.asset.url, stem: target.asset.stem,
            savedPath: savedPath, bytes: bytes, summary: summary,
            status: status, meta: target.meta, downloadedAt: stamp
        )
    }
}

extension LottieAsset {
    /// Same identity/source/stem, different stored kind (used when writing an
    /// extracted JSON sibling of a dotLottie).
    func withKind(_ kind: AssetKind) -> LottieAsset {
        LottieAsset(url: url, source: source, kind: kind, animationId: animationId, stem: stem)
    }
}
