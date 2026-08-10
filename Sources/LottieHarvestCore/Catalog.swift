import Foundation
import os

/// Append-only, on-disk catalog of every harvested asset (JSONL).
///
/// One line per `CatalogEntry`. Re-runs skip animations whose id already has a
/// successful entry, so harvesting is resumable and idempotent across runs.
public actor Catalog {

    public struct Summary: Sendable, Equatable {
        public let total: Int
        public let ok: Int
        public let skipped: Int
        public let invalid: Int
        public let failed: Int
        public let bytes: Int
        public init(total: Int, ok: Int, skipped: Int, invalid: Int, failed: Int, bytes: Int) {
            self.total = total; self.ok = ok; self.skipped = skipped
            self.invalid = invalid; self.failed = failed; self.bytes = bytes
        }
    }

    private let fileURL: URL
    private var entries: [CatalogEntry] = []
    private var okIds: Set<String> = []

    public init(fileURL: URL) async {
        self.fileURL = fileURL
        load()
    }

    /// True if this kind-qualified identity already has a successful entry.
    /// Keyed by `kind:animationId` so lottie+json variants of one animation
    /// can coexist when pulling `--format both`.
    public func containsSuccessful(_ identity: String) -> Bool { okIds.contains(identity) }

    public func existingSuccessfulIds() -> Set<String> { okIds }

    public func append(_ entry: CatalogEntry) {
        entries.append(entry)
        if entry.status == .ok { okIds.insert(entry.identity) }
        Logger.catalog.info("📓 \(entry.status.rawValue, privacy: .public) \(entry.animationId, privacy: .public) (\(entry.bytes)B)")
    }

    /// Write the full catalog back as JSONL (atomic).
    public func flush() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        try payload.write(to: fileURL, options: .atomic)
    }

    public func snapshot() -> [CatalogEntry] { entries }

    public func summary() -> Summary {
        var ok = 0, skipped = 0, invalid = 0, failed = 0, bytes = 0
        for e in entries {
            bytes += e.bytes
            switch e.status {
            case .ok:      ok += 1
            case .skipped: skipped += 1
            case .invalid: invalid += 1
            case .failed:  failed += 1
            }
        }
        return Summary(total: entries.count, ok: ok, skipped: skipped,
                       invalid: invalid, failed: failed, bytes: bytes)
    }

    // MARK: private

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(CatalogEntry.self, from: lineData) else {
                continue
            }
            entries.append(entry)
            if entry.status == .ok { okIds.insert(entry.identity) }
        }
        Logger.catalog.info("📓 loaded \(self.entries.count) existing catalog entries")
    }
}

public struct CatalogEntry: Codable, Sendable, Equatable {
    public enum Status: String, Sendable, Codable {
        case ok, skipped, invalid, failed
    }

    public let animationId: String
    public let source: AssetSource
    public let kind: AssetKind
    public let url: URL
    public let stem: String
    public let savedPath: String
    public let bytes: Int
    public let summary: String
    public let status: Status
    public let meta: AnimationMeta?
    public let downloadedAt: Date

    public init(
        animationId: String, source: AssetSource, kind: AssetKind, url: URL,
        stem: String, savedPath: String, bytes: Int, summary: String,
        status: Status, meta: AnimationMeta? = nil, downloadedAt: Date = .now
    ) {
        self.animationId = animationId; self.source = source; self.kind = kind
        self.url = url; self.stem = stem; self.savedPath = savedPath
        self.bytes = bytes; self.summary = summary; self.status = status
        self.meta = meta; self.downloadedAt = downloadedAt
    }

    /// Kind-qualified identity used for resumability and dedupe.
    public var identity: String { "\(kind.rawValue):\(animationId)" }
}
