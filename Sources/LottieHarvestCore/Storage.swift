import Foundation
import os

/// Filesystem writer + dotLottie extractor.
///
/// Filenames are derived from the stable animation identity (never the remote
/// filename alone) so re-harvesting the same animation is a no-op. dotLottie
/// extraction shells out to the system `unzip` (no pure-Swift zip dep needed).
public enum Storage {

    public struct DotLottieContents: Sendable, Equatable {
        public let animationCount: Int
        /// First inner animation JSON bytes (for `--format json` flattening).
        public let primaryAnimationJSON: Data?
    }

    /// Compute the on-disk path for an asset under `root`.
    public static func savePath(for asset: LottieAsset, root: URL) -> URL {
        let folder = root.appendingPathComponent(asset.source.rawValue, isDirectory: true)
        // animationId is e.g. "<uuid>/<stem>"; flatten to a safe single filename.
        let flat = asset.animationId.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(flat).\(asset.kind.fileExtension)")
    }

    public static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    public static func write(_ data: Data, for asset: LottieAsset, root: URL) throws -> URL {
        let path = savePath(for: asset, root: root)
        try ensureDir(path.deletingLastPathComponent())
        try data.write(to: path, options: .atomic)
        return path
    }

    /// Unpack a `.lottie` zip into a throwaway temp dir, read its manifest to
    /// count animations, and return the first inner animation JSON bytes. The
    /// temp dir is always removed, so extraction leaves no on-disk clutter.
    public static func extractDotLottie(_ data: Data) throws -> DotLottieContents {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("lottie-harvest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let zipFile = scratch.appendingPathComponent("payload.lottie")
        try data.write(to: zipFile, options: .atomic)

        try runProcess(
            command: "/usr/bin/unzip",
            arguments: ["-o", zipFile.path, "-d", scratch.path]
        )

        let manifestURL = scratch.appendingPathComponent("manifest.json")
        var count = 0
        if let manifestData = try? Data(contentsOf: manifestURL),
           let object = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
           let animations = object["animations"] as? [Any] {
            count = animations.count
        }

        let primaryData = firstAnimationJSON(in: scratch).flatMap { try? Data(contentsOf: $0) }
        Logger.storage.info("🗄️ unpacked dotLottie (\(count) anims)")
        return DotLottieContents(animationCount: count, primaryAnimationJSON: primaryData)
    }

    // MARK: Internals

    /// Recursively find the first plausible Lottie animation JSON in a directory.
    static func firstAnimationJSON(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "json" {
            // Skip manifest.json itself.
            if url.lastPathComponent == "manifest.json" { continue }
            return url
        }
        return nil
    }

    @discardableResult
    static func runProcess(command: String, arguments: [String]) throws -> String {
#if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Storage", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(command) failed: \(output)"])
        }
        return output
#else
        // No `Process` on iOS/watchOS/tvOS — dotLottie extraction is unavailable there.
        throw NSError(
            domain: "Storage", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "external process unavailable on this platform"])
#endif
    }
}
