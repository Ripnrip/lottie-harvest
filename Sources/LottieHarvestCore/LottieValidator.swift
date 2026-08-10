import Foundation

/// Validates downloaded blobs against their claimed `AssetKind`.
///
/// JSON validation uses `JSONSerialization` (tolerant to bodymovin schema drift
/// across versions) and surfaces a small summary for the catalog. dotLottie
/// validation confirms the zip container magic; animation counting happens after
/// extraction (see `Storage.extractDotLottie`) since the manifest is compressed.
public enum LottieValidator {

    public static func validate(_ data: Data, kind: AssetKind) -> ValidationResult {
        switch kind {
        case .json:      validateJSON(data)
        case .dotLottie: validateDotLottie(data)
        case .thumbnail: validateImage(data)
        }
    }

    // MARK: JSON

    public static func validateJSON(_ data: Data) -> ValidationResult {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .invalid(reason: "not parseable JSON")
        }
        // Accept either a single animation object or an array whose first
        // element is an animation (some exports wrap the body).
        let dict: [String: Any]
        if let d = any as? [String: Any] {
            dict = d
        } else if let arr = any as? [Any], let first = arr.first as? [String: Any] {
            dict = first
        } else {
            return .invalid(reason: "JSON is neither object nor animation array")
        }

        // A real Lottie has layers and/or an assets array and a version marker.
        let layers = (dict["layers"] as? [Any]) ?? []
        let assets = (dict["assets"] as? [Any]) ?? []
        let version = dict["v"]
        guard !layers.isEmpty || version != nil || !assets.isEmpty else {
            return .invalid(reason: "missing Lottie markers (v/layers/assets)")
        }

        func num(_ key: String) -> Double {
            switch dict[key] {
            case let n as Double: n
            case let n as Int:    Double(n)
            default:              0
            }
        }
        let summary = LottieSpecSummary(
            version: (version.flatMap { $0 as? String }) ?? "?",
            frameRate: num("fr"),
            width: num("w"),
            height: num("h"),
            layerCount: layers.count,
            inPoint: num("ip"),
            outPoint: num("op")
        )
        return .validLottieJSON(spec: summary)
    }

    // MARK: dotLottie (zip container)

    public static func validateDotLottie(_ data: Data) -> ValidationResult {
        guard data.count > 4 else {
            return .invalid(reason: "dotLottie payload too small")
        }
        // ZIP local-file-header magic: 0x50 0x4B 0x03 0x04 ("PK\x03\x04").
        // Empty-archive magic (0x50 0x4B 0x05 0x06) is also valid but we expect
        // at least one entry, so accept the file-header signature.
        let pk: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let prefix = [UInt8](data.prefix(4))
        guard prefix == pk else {
            return .invalid(reason: "not a zip container (missing PK\\x03\\x04)")
        }
        return .validDotLottie(animationCount: 0)
    }

    // MARK: Images

    public static func validateImage(_ data: Data) -> ValidationResult {
        guard data.count > 8 else { return .invalid(reason: "image payload too small") }
        let bytes = [UInt8](data.prefix(12))
        let isPNG  = Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let isJPEG = Array(bytes.prefix(3)) == [0xFF, 0xD8, 0xFF]
        let isGIF  = Array(bytes.prefix(6)) == [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]
                     || Array(bytes.prefix(6)) == [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        // WEBP: "RIF....WEBP"
        let isWEBP = Array(bytes.prefix(4)) == [0x52, 0x49, 0x46, 0x46]
                     && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
        if isPNG || isJPEG || isGIF || isWEBP { return .validImage }
        return .invalid(reason: "unrecognized image magic bytes")
    }
}
