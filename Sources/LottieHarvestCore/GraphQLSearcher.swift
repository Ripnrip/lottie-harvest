import Foundation
import os

/// Cloudflare-free, auth-free discovery via LottieFiles' public GraphQL API
/// (`graphql.lottiefiles.com`).
///
/// This is the primary discovery path: keyword search + curated/popular/recent/
/// featured collections, all returning exact `lottieUrl` / `jsonUrl` / `imageUrl`
/// on the open `assets-v2` CDN. Each node fans out into up to three classified
/// `LottieAsset` variants sharing the animation's `uuid` as identity, so the
/// harvester can pick the right real URL per requested format.
public struct GraphQLSearcher: Sendable {

    public enum Collection: String, Sendable, CaseIterable {
        case popular, recent, featured, curated

        public var field: String { "\(rawValue)PublicAnimations" }
    }

    private static let endpoint = URL(string: "https://graphql.lottiefiles.com/")!
    private let session: URLSession
    private let pageSize: Int
    private let maxPages: Int

    public init(pageSize: Int = 50, maxPages: Int = 200, timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = [
            "User-Agent": Downloader.browserUA,
            "Origin": "https://lottiefiles.com",
            "Referer": "https://lottiefiles.com/",
        ]
        self.session = URLSession(configuration: config)
        self.pageSize = max(1, min(100, pageSize))
        self.maxPages = max(1, maxPages)
    }

    // MARK: Public discovery

    public func search(_ query: String, limit: Int?) async -> [Animation] {
        let operation = """
        query($q:String!,$n:Int!,$c:String){
          searchPublicAnimations(query:$q,first:$n,after:$c){
            edges{node{uuid name slug lottieUrl jsonUrl imageUrl downloads likesCount frameRate publishedAt createdBy{name username}}}
            pageInfo{endCursor hasNextPage}
          }
        }
        """
        return await paginate(
            operation: operation,
            connectionField: "searchPublicAnimations",
            variables: ["q": query],
            nodeLimit: limit,
            collection: query
        )
    }

    public func browse(
        _ collection: Collection,
        category: String? = nil,
        limit: Int? = nil
    ) async -> [Animation] {
        let hasCategory = collection == .curated && category != nil
        let operation: String
        var baseVars: [String: Any] = [:]
        switch collection {
        case .popular:
            operation = """
            query($n:Int!,$c:String){
              popularPublicAnimations(first:$n,after:$c){
                edges{node{uuid name slug lottieUrl jsonUrl imageUrl downloads likesCount frameRate publishedAt createdBy{name username}}}
                pageInfo{endCursor hasNextPage}
              }
            }
            """
        case .recent:
            operation = """
            query($n:Int!,$c:String){
              recentPublicAnimations(first:$n,after:$c){
                edges{node{uuid name slug lottieUrl jsonUrl imageUrl downloads likesCount frameRate publishedAt createdBy{name username}}}
                pageInfo{endCursor hasNextPage}
              }
            }
            """
        case .featured:
            operation = """
            query($n:Int!,$c:String){
              featuredPublicAnimations(first:$n,after:$c){
                edges{node{uuid name slug lottieUrl jsonUrl imageUrl downloads likesCount frameRate publishedAt createdBy{name username}}}
                pageInfo{endCursor hasNextPage}
              }
            }
            """
        case .curated:
            baseVars["cat"] = category ?? ""
            baseVars["ctype"] = "category"
            operation = """
            query($n:Int!,$c:String,$cat:String,$ctype:String!){
              curatedPublicAnimations(curationType:$ctype,category:$cat,first:$n,after:$c){
                edges{node{uuid name slug lottieUrl jsonUrl imageUrl downloads likesCount frameRate publishedAt createdBy{name username}}}
                pageInfo{endCursor hasNextPage}
              }
            }
            """
        }
        _ = hasCategory
        let collectionLabel = collection == .curated ? (category ?? "curated") : collection.rawValue
        return await paginate(
            operation: operation,
            connectionField: collection.field,
            variables: baseVars,
            nodeLimit: limit,
            collection: collectionLabel
        )
    }

    // MARK: Internals

    private func paginate(
        operation: String,
        connectionField: String,
        variables: [String: Any],
        nodeLimit: Int?,
        collection: String
    ) async -> [Animation] {
        var all: [Animation] = []
        var cursor: Any = NSNull()
        var nodes = 0
        var pages = 0

        while pages < maxPages {
            pages += 1
            if let nodeLimit, nodes >= nodeLimit { break }
            let remaining = nodeLimit.map { $0 - nodes }
            let size = min(pageSize, remaining ?? pageSize)

            var vars = variables
            vars["n"] = size
            vars["c"] = cursor

            guard let result = try? await run(operation: operation, variables: vars),
                  let connection = result[connectionField] as? [String: Any] else {
                Logger.discovery.error("🛰️ GraphQL: no '\(connectionField, privacy: .public)' in response")
                break
            }

            let edges = (connection["edges"] as? [[String: Any]]) ?? []
            if edges.isEmpty { break }

            for edge in edges {
                guard let node = edge["node"] as? [String: Any] else { continue }
                nodes += 1
                if let anim = animation(from: node, collection: collection) { all.append(anim) }
                if let nodeLimit, nodes >= nodeLimit { break }
            }

            let pageInfo = (connection["pageInfo"] as? [String: Any]) ?? [:]
            let hasNext = (pageInfo["hasNextPage"] as? Bool) ?? false
            Logger.discovery.info("🛰️ \(connectionField, privacy: .public) page \(pages): +\(edges.count) (nodes \(nodes))")
            guard let nodeLimit, nodes >= nodeLimit else {
                guard hasNext, let next = pageInfo["endCursor"] as? String, !next.isEmpty else { break }
                cursor = next
                continue
            }
            break
        }
        return all
    }

    private func run(operation: String, variables: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "query": operation,
            "variables": variables,
        ])
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        if let errors = json["errors"] {
            Logger.discovery.error("🛰️ GraphQL errors: \(String(describing: errors), privacy: .public)")
        }
        return (json["data"] as? [String: Any]) ?? [:]
    }

    /// Build an `Animation` (variants + metadata) from a GraphQL node.
    private func animation(from node: [String: Any], collection: String) -> Animation? {
        guard let uuid = node["uuid"] as? String, !uuid.isEmpty else { return nil }
        var variants: [LottieAsset] = []
        for key in ["lottieUrl", "jsonUrl", "imageUrl"] {
            if let raw = node[key] as? String, let asset = AssetDiscovery.classify(rawUrl: raw) {
                variants.append(asset)
            }
        }
        guard !variants.isEmpty else { return nil }

        let creator = node["createdBy"] as? [String: Any]
        let slug = (node["slug"] as? String) ?? uuid
        let meta = AnimationMeta(
            name: (node["name"] as? String) ?? slug,
            slug: slug,
            author: creator?["name"] as? String,
            authorUsername: creator?["username"] as? String,
            downloads: (node["downloads"] as? Int) ?? (node["downloads"] as? Double).map(Int.init),
            likes: node["likesCount"] as? Int,
            frameRate: (node["frameRate"] as? Double) ?? (node["frameRate"] as? Int).map(Double.init),
            publishedAt: node["publishedAt"] as? String,
            pageURL: URL(string: "https://lottiefiles.com/animation/\(slug)"),
            thumbnailURL: (node["imageUrl"] as? String).flatMap(URL.init(string:)),
            collection: collection
        )
        return Animation(id: uuid, variants: variants, meta: meta)
    }
}
