#!/usr/bin/env swift
//
// deploy-gallery.swift — force-deploy a static site directory to the `gh-pages` branch.
//
//   swift Scripts/deploy-gallery.swift <site-dir>
//
// Pure Foundation + `git` via Process. Creates/resets an orphan `gh-pages`
// branch to contain exactly the files in <site-dir> (plus .nojekyll), then
// force-pushes. Auth via GH_TOKEN (GITHUB_TOKEN in CI).
//
import Foundation

// MARK: - Args + env

let cliArgs = Array(CommandLine.arguments.dropFirst())
guard let siteArg = cliArgs.first else { fail("usage: deploy-gallery.swift <site-dir>") }

let siteDir = URL(fileURLWithPath: siteArg, isDirectory: true)
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: siteDir.path, isDirectory: &isDir), isDir.boolValue else {
    fail("site dir not found: \(siteArg)")
}
let siteAbs = URL(fileURLWithPath: (siteDir.path as NSString).standardizingPath, isDirectory: true)

let env = ProcessInfo.processInfo.environment
let repo   = env["GITHUB_REPOSITORY"] ?? "Ripnrip/lottie-harvest"
let branch = "gh-pages"
guard let token = env["GH_TOKEN"] ?? env["GITHUB_TOKEN"] else {
    fail("GH_TOKEN env var required for push")
}
let remoteHTTPS = "https://github.com/\(repo).git"
let pushRemote  = "https://x-access-token:\(token)@github.com/\(repo).git"

// MARK: - Temp work dir

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("lh-deploy-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

// MARK: - Clone + orphan

run("/usr/bin/git", ["clone", "--quiet", remoteHTTPS, work.path])
git(work, ["checkout", "--quiet", "--orphan", branch])
git(work, ["rm", "-rf", "--quiet", "."], allowFail: true)   // clear tracked tree

// MARK: - Copy site contents

copyContents(of: siteAbs, into: work)
try Data().write(to: work.appendingPathComponent(".nojekyll"))   // serve as-is (no Jekyll)
git(work, ["add", "-A"])

// MARK: - Commit + force-push

git(work, [
    "-c", "user.name=github-actions[bot]",
    "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
    "commit", "-q", "-m", "gallery deploy: \(isoNow())",
])
git(work, ["push", "--quiet", "--force", pushRemote, branch])

print("✅ deployed \(siteAbs.path) → \(repo):\(branch)")

// MARK: - Helpers

@inline(__always) func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✖ \(message)\n".utf8))
    exit(1)
}

/// Run a process; returns exit status. Fails hard unless `allowFail`.
@discardableResult
func run(_ exe: String, _ args: [String], cwd: URL? = nil, allowFail: Bool = false) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = cwd }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { if !allowFail { fail("couldn't run \(exe): \(error)") }; return -1 }
    process.waitUntilExit()
    if process.terminationStatus != 0 && !allowFail {
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        fail("\(exe) \(args.joined(separator: " ")) failed (\(process.terminationStatus)): \(out)")
    }
    return process.terminationStatus
}

/// `git` shorthand pinned to a working directory.
func git(_ cwd: URL, _ args: [String], allowFail: Bool = false) {
    _ = run("/usr/bin/git", args, cwd: cwd, allowFail: allowFail)
}

/// Copy every top-level entry (including dotfiles) from `src` into `dst`.
func copyContents(of src: URL, into dst: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []
    for name in names {
        let from = src.appendingPathComponent(name)
        let to   = dst.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: to)        // overwrite if present
        do { try FileManager.default.copyItem(at: from, to: to) }
        catch { fail("copy failed for \(name): \(error)") }
    }
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}
