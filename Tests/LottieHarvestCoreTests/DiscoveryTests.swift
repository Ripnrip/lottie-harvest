import Foundation
import LottieHarvestCore
import Testing

struct DiscoveryTests {
    private func loadFixture(_ name: String, ext: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Discovers all asset URLs from a gallery fixture")
    func discoversAll() throws {
        let html = try loadFixture("gallery", ext: "html")
        let raw = AssetDiscovery.discoverAssets(in: html)
        // 3 v2 variants + 1 packages + 1 host = 5 raw refs
        #expect(raw.count == 5)
    }

    @Test("Dedupe collapses ext variants and keeps dotLottie")
    func dedupeKeepsRichest() throws {
        let html = try loadFixture("gallery", ext: "html")
        let deduped = AssetDiscovery.dedupe(AssetDiscovery.discoverAssets(in: html))
        // 3 unique animations: v2 (CRB3N04hsX), packages (lf20_jbrw3hcz), host (LIxC7hRf1W)
        #expect(deduped.count == 3)

        let v2 = try #require(deduped.first { $0.source == .lottiefilesV2 })
        #expect(v2.kind == .dotLottie)
        #expect(v2.stem == "CRB3N04hsX")
        #expect(v2.animationId == "071fd25b-067a-4e16-a5ab-470c805442cf")

        let pkg = try #require(deduped.first { $0.source == .lottiefilesPackages })
        #expect(pkg.kind == .json)
        #expect(pkg.stem == "lf20_jbrw3hcz")
    }

    @Test("Classifies protocol-relative, absolute, and path-only URLs")
    func classifyVariants() {
        #expect(AssetDiscovery.classify(rawUrl: "//assets-v2.lottiefiles.com/a/071fd25b-067a-4e16-a5ab-470c805442cf/X.lottie")?.kind == .dotLottie)
        #expect(AssetDiscovery.classify(rawUrl: "https://lottie.host/9d44a4bd-bb72-4d1f-bc0d-1bb8c7f0b7c1/Y.json")?.source == .lottieHost)
        #expect(AssetDiscovery.classify(rawUrl: "/animation/foo") == nil)
        #expect(AssetDiscovery.classify(rawUrl: "https://example.com/x.json") == nil)
    }

    @Test("Extracts animation-page links for recursion")
    func animationPages() throws {
        let html = try loadFixture("gallery", ext: "html")
        let pages = AssetDiscovery.discoverAnimationPages(in: html)
        #expect(pages.count == 2)
        #expect(pages.contains { $0.absoluteString.hasSuffix("/animation/success-animation_13335262") })
    }

    @Test("Ignores non-lottie CDN noise")
    func ignoresNoise() {
        let html = "https://accounts-assets.lottiefiles.com/avatars/x.png https://app.lottiefiles.com/login"
        #expect(AssetDiscovery.discoverAssets(in: html).isEmpty)
    }
}
