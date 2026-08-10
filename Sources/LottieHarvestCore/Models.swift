import Foundation

// MARK: - Enums (exhaustive, Sendable, value-typed)

/// Where a discovered asset physically lives. Drives naming + catalog source attribution.
public enum AssetSource: String, Sendable, Codable, CaseIterable {
    case lottiefilesV2       // assets-v2.lottiefiles.com/a/<uuid>/<id>
    case lottiefilesPackages // assets{N}.lottiefiles.com/packages/lf<id>
    case lottieHost          // lottie.host/<uuid>/<name>
    case iconscout           // cdnl.iconscout.com/lottie/...
    case unknown

    public var displayName: String {
        switch self {
        case .lottiefilesV2:       "LottieFiles (v2)"
        case .lottiefilesPackages: "LottieFiles (packages)"
        case .lottieHost:          "LottieHost"
        case .iconscout:           "Iconscout"
        case .unknown:             "Unknown"
        }
    }
}

/// Physical asset format, derived from the URL extension. Decides validation + storage.
public enum AssetKind: String, Sendable, Codable, CaseIterable {
    case dotLottie   // .lottie  → zip container (manifest.json + animations/*.json + images/*)
    case json        // .json    → raw Lottie bodymovin JSON
    case thumbnail   // .png/.jpg/.webp/.gif preview image

    public var isPrimary: Bool {
        switch self {
        case .dotLottie, .json: true
        case .thumbnail:        false
        }
    }

    public var fileExtension: String {
        switch self {
        case .dotLottie: "lottie"
        case .json:      "json"
        case .thumbnail: "png"
        }
    }
}

/// What the user wants pulled off disk, independent of what was discovered.
public enum PullFormat: String, Sendable, Codable, CaseIterable {
    case dotLottie
    case json
    case both
}

/// Outcome of validating a downloaded blob against its claimed kind.
public enum ValidationResult: Sendable, Equatable {
    case validLottieJSON(spec: LottieSpecSummary)
    case validDotLottie(animationCount: Int)
    case validImage
    case invalid(reason: String)

    public var isValid: Bool {
        switch self {
        case .invalid: false
        default:       true
        }
    }
}

// MARK: - Lottie asset model

/// A single discovered asset URL, fully identified + classified.
/// Identity is the *animation* (uuid + stem), so `.lottie`/`.json`/`.png`
/// variants of the same animation collapse to one id and dedupe correctly.
public struct LottieAsset: Sendable, Hashable, Identifiable, Codable {
    public let url: URL
    public let source: AssetSource
    public let kind: AssetKind
    /// Stable animation identity: `uuid/stem` for v2/host, `lf<id>` for packages.
    public let animationId: String
    /// Human-ish stem used for filenames (e.g. `CRB3N04hsX`, `lf20_jbrw3hcz`).
    public let stem: String

    public var id: String { animationId }

    /// Kind-qualified identity (`kind:animationId`) — matches `CatalogEntry.identity`
    /// so resumability and logging share one notion of “same file”.
    public var identity: String { "\(kind.rawValue):\(animationId)" }

    public init(url: URL, source: AssetSource, kind: AssetKind, animationId: String, stem: String) {
        self.url = url
        self.source = source
        self.kind = kind
        self.animationId = animationId
        self.stem = stem
    }
}

/// Lightweight summary extracted from a parsed Lottie JSON (enough to catalog,
/// not a full bodymovin schema).
public struct LottieSpecSummary: Sendable, Equatable, Codable {
    public let version: String
    public let frameRate: Double
    public let width: Double
    public let height: Double
    public let layerCount: Int
    public let inPoint: Double
    public let outPoint: Double
}

// MARK: - Animation metadata + aggregate

/// Provenance/metadata for a discovered animation. Optional throughout — the HTML
/// and URL-list discovery paths produce `nil`; GraphQL discovery fills it in.
public struct AnimationMeta: Sendable, Codable, Equatable {
    public let name: String
    public let slug: String
    public let author: String?
    public let authorUsername: String?
    public let downloads: Int?
    public let likes: Int?
    public let frameRate: Double?
    public let publishedAt: String?      // raw ISO8601, kept as string for robustness
    public let pageURL: URL?
    public let thumbnailURL: URL?

    public init(name: String, slug: String, author: String?, authorUsername: String?,
                downloads: Int?, likes: Int?, frameRate: Double?, publishedAt: String?,
                pageURL: URL?, thumbnailURL: URL?) {
        self.name = name; self.slug = slug; self.author = author
        self.authorUsername = authorUsername; self.downloads = downloads; self.likes = likes
        self.frameRate = frameRate; self.publishedAt = publishedAt
        self.pageURL = pageURL; self.thumbnailURL = thumbnailURL
    }
}

/// One animation = stable identity (`uuid`) + its asset URL variants + optional
/// metadata. This is the unit the harvester plans and the catalog records.
public struct Animation: Sendable, Identifiable, Equatable {
    public let id: String
    public let variants: [LottieAsset]
    public let meta: AnimationMeta?

    public init(id: String, variants: [LottieAsset], meta: AnimationMeta?) {
        self.id = id; self.variants = variants; self.meta = meta
    }

    /// Group raw discovered assets (no metadata) into animations by identity.
    public static func grouping(_ assets: [LottieAsset]) -> [Animation] {
        Dictionary(grouping: assets, by: \.animationId)
            .map { Animation(id: $0.key, variants: $0.value, meta: nil) }
            .sorted { $0.id < $1.id }
    }
}
