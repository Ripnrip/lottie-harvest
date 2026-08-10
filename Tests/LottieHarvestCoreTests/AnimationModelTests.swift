import Foundation
import LottieHarvestCore
import Testing

struct AnimationModelTests {
    private func asset(_ id: String, _ ext: String, _ kind: AssetKind) -> LottieAsset {
        LottieAsset(
            url: URL(string: "https://assets-v2.lottiefiles.com/a/\(id)/x.\(ext)")!,
            source: .lottiefilesV2, kind: kind,
            animationId: id, stem: "x"
        )
    }

    @Test("grouping folds variants of one animation together")
    func grouping() {
        let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let animations = Animation.grouping([
            asset(id, "X.lottie", .dotLottie),
            asset(id, "Y.json", .json),
            asset(id, "Z.png", .thumbnail),
            asset("zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz", "Q.lottie", .dotLottie),
        ])
        #expect(animations.count == 2)
        let main = animations.first { $0.id == id }!
        #expect(main.variants.count == 3)
        #expect(main.meta == nil)
    }

    @Test("AnimationMeta round-trips through Codable")
    func metaCodable() throws {
        let meta = AnimationMeta(
            name: "apple", slug: "apple", author: "Bali", authorUsername: "/bali",
            downloads: 74, likes: 3, frameRate: 60, publishedAt: "2021-08-08T06:09:36.000Z",
            pageURL: URL(string: "https://lottiefiles.com/animation/apple"),
            thumbnailURL: URL(string: "https://assets-v2.lottiefiles.com/a/x/y.png")
        )
        let encoded = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(AnimationMeta.self, from: encoded)
        #expect(decoded == meta)
    }
}
