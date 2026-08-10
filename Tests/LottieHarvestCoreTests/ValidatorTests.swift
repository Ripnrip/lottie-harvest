import Foundation
import LottieHarvestCore
import Testing

struct ValidatorTests {
    @Test("Validates a real Lottie JSON and extracts a summary")
    func validatesJSON() throws {
        let url = try #require(
            Bundle.module.url(forResource: "good", withExtension: "json", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        let result = LottieValidator.validate(data, kind: .json)
        guard case .validLottieJSON(let spec) = result else {
            Issue.record("expected validLottieJSON, got \(result)"); return
        }
        #expect(spec.version == "5.7.0")
        #expect(spec.frameRate == 30)
        #expect(spec.width == 200)
        #expect(spec.height == 200)
        #expect(spec.layerCount == 1)
    }

    @Test("Rejects malformed JSON")
    func rejectsMalformed() {
        let result = LottieValidator.validate(Data("{not json".utf8), kind: .json)
        if case .invalid = result { /* ok */ } else { Issue.record("expected invalid") }
    }

    @Test("Rejects JSON without Lottie markers")
    func rejectsNonLottie() {
        let result = LottieValidator.validate(Data("{\"hello\":\"world\"}".utf8), kind: .json)
        if case .invalid = result { /* ok */ } else { Issue.record("expected invalid") }
    }

    @Test("Validates dotLottie zip magic")
    func validatesDotLottieMagic() {
        let pk = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 32)
        if case .validDotLottie = LottieValidator.validate(pk, kind: .dotLottie) { /* ok */ }
        else { Issue.record("expected validDotLottie") }

        let notZip = Data("PKnotreally".utf8)
        if case .invalid = LottieValidator.validate(notZip, kind: .dotLottie) { /* ok */ }
        else { Issue.record("expected invalid for bad magic") }
    }

    @Test("Validates image magic bytes")
    func validatesImages() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 16)
        if case .validImage = LottieValidator.validate(png, kind: .thumbnail) { /* ok */ }
        else { Issue.record("expected validImage PNG") }

        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 16)
        if case .validImage = LottieValidator.validate(jpg, kind: .thumbnail) { /* ok */ }
        else { Issue.record("expected validImage JPEG") }

        let bad = Data("notanimage".utf8)
        if case .invalid = LottieValidator.validate(bad, kind: .thumbnail) { /* ok */ }
        else { Issue.record("expected invalid image") }
    }
}

struct HarvesterTargetsTests {
    private let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private func asset(_ stem: String, _ ext: String, _ kind: AssetKind) -> LottieAsset {
        LottieAsset(
            url: URL(string: "https://assets-v2.lottiefiles.com/a/\(uuid)/\(stem).\(ext)")!,
            source: .lottiefilesV2, kind: kind,
            animationId: uuid, stem: stem
        )
    }

    @Test("format both yields json + dotLottie when both URLs known")
    func bothWithBothURLs() {
        let targets = Harvester.targets(for: [asset("A", "lottie", .dotLottie), asset("B", "json", .json)],
                                        format: .both, includeThumbnails: false)
        #expect(targets.count == 2)
        #expect(targets.contains { $0.storeAs == .json })
        #expect(targets.contains { $0.storeAs == .dotLottie })
        #expect(targets.allSatisfy { !$0.alsoExtractJSON })
    }

    @Test("format both with dotLottie only plans a single download + extract")
    func bothDotLottieOnlyExtracts() {
        let targets = Harvester.targets(for: [asset("A", "lottie", .dotLottie)],
                                        format: .both, includeThumbnails: false)
        #expect(targets.count == 1)
        #expect(targets.first?.alsoExtractJSON == true)
        #expect(targets.first?.storeAs == .dotLottie)
    }

    @Test("packages source stays json even under dotLottie format")
    func packagesJsonOnly() {
        let pkg = LottieAsset(
            url: URL(string: "https://assets3.lottiefiles.com/packages/lf20_abc.json")!,
            source: .lottiefilesPackages, kind: .json,
            animationId: "packages/lf20_abc", stem: "lf20_abc"
        )
        let targets = Harvester.targets(for: [pkg], format: .dotLottie, includeThumbnails: false)
        #expect(targets.count == 1)
        #expect(targets.first?.storeAs == .json)
    }

    @Test("json format extracts when only dotLottie is available")
    func jsonExtracts() {
        let targets = Harvester.targets(for: [asset("A", "lottie", .dotLottie)],
                                        format: .json, includeThumbnails: false)
        #expect(targets.count == 1)
        #expect(targets.first?.storeAs == .json)
        #expect(targets.first?.asset.kind == .dotLottie)
    }

    @Test("thumbnails flag adds a png target")
    func thumbs() {
        let variants = [asset("A", "lottie", .dotLottie), asset("A", "png", .thumbnail)]
        let targets = Harvester.targets(for: variants, format: .dotLottie, includeThumbnails: true)
        #expect(targets.contains { $0.storeAs == .thumbnail })
    }
}
