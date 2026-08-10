# LottieHarvest

Bulk-scrape and download Lottie animations (dotLottie + Lottie JSON) from
LottieFiles' **open asset CDN** — no per-asset clicking, no manual sourcing.

A Swift 6 Package (library `LottieHarvestCore` + `lottie-harvest` CLI), written
to the [swift-canon](../swift-canon/SKILL.md) discipline (Swift 6 concurrency,
`Sendable`/actors, exhaustive enums, `os.Logger`, functional core, swift-testing).

## Why this works

LottieFiles' **browse layer** (gallery/search pages) is behind Cloudflare, but:

- The **asset CDN** (`assets-v2.lottiefiles.com/a/<uuid>/<id>.{lottie,json,png}` and
  legacy `assets*.lottiefiles.com/packages/lf*.json`) is **open** — direct 200s, no challenge.
- The **public GraphQL API** (`graphql.lottiefiles.com`) is **open** (no auth, no
  Cloudflare) and exposes `searchPublicAnimations`, `popularPublicAnimations`, …,
  each returning exact `lottieUrl` / `jsonUrl` / `imageUrl` + cursor pagination.

So discovery runs entirely through GraphQL (no browser needed), and downloads go
straight to the CDN. The browser path is kept only as a fallback for other sources.

## Use as a Swift Package dependency

The library product is `LottieHarvestCore` (the CLI is separate). Add this package
(local path or git URL) in Xcode / `Package.swift`, then:

```swift
import LottieHarvestCore

// Discover via the open GraphQL API (no browser, no Cloudflare):
let searcher = GraphQLSearcher()
let animations: [Animation] = await searcher.search("loading", limit: 50)
// each Animation carries .variants (lottie/json/png URLs) + .meta (name, author, downloads…)

// Download to disk with validation + a resumable catalog:
let options = HarvesterOptions(
    root: URL(fileURLWithPath: "./assets", isDirectory: true),
    concurrency: 12,
    pullFormat: .both            // .dotLottie | .json | .both
)
let catalog = await Catalog(fileURL: options.root.appendingPathComponent("catalog.jsonl"))
let report = try await Harvester.pull(animations, options: options, into: catalog)
print(report)                    // discovered / downloaded / skipped / bytes

// Or work from URLs you already have (e.g. harvested by a browser tool):
let assets = urls.compactMap { AssetDiscovery.classify(rawUrl: $0) }
try await Harvester.pull(Animation.grouping(assets), options: options, into: catalog)
```

**Platforms:** macOS 14+, iOS 17+. The core (search, classify, download, validate,
catalog) is fully cross-platform. dotLottie→JSON extraction shells out to `unzip`
via `Process`, so it is available on **macOS/Linux** and gracefully no-ops on **iOS**
(stores the `.lottie` as-is; your Lottie player handles it).

**Public API surface:** `GraphQLSearcher`, `AssetDiscovery`, `Animation`/`AnimationMeta`,
`LottieAsset`/`AssetKind`/`AssetSource`/`PullFormat`, `LottieValidator`,
`Downloader`, `Storage`, `Catalog`/`CatalogEntry`, `Harvester`/`HarvesterOptions`/
`HarvestReport`, `PageFetcher`/`StaticFetcher` (and `HeadlessChromeFetcher` on macOS/Linux).

## Gallery

A live, self-contained HTML gallery of harvested animations is generated from any
`catalog.jsonl` and deployed via GitHub Pages:

```bash
lottie-harvest gallery --catalog catalog.jsonl --output index.html --title "My Gallery"
```

Each card lazy-loads its player from the open LottieFiles asset CDN and shows
name / author / downloads, with links to the LottieFiles page and the `.lottie`
+ `.json` downloads. Filter live by name or author.

**Live gallery:** <https://ripnrip.github.io/lottie-harvest/> (216 animations)

## Build & test

```bash
swift build            # Swift 6, macOS 14+
swift test             # 15 hermetic tests (discovery, validation, planning)
```

## Usage

```bash
# Search by keyword (this is what /free-animations/<q> shows in the browser):
lottie-harvest search "apple" --limit 20 --format both --out ./assets

# Browse a collection (popular | recent | featured | curated):
lottie-harvest browse popular --limit 50 --out ./assets
lottie-harvest browse curated --category loading --limit 40 --out ./assets

# Dry-run (list discovered URLs, no download):
lottie-harvest search "loading" --limit 10 --dry-run

# Pull a known list of asset URLs (or --from a file, e.g. browsermcp output):
lottie-harvest pull --from urls.txt --format dotLottie --out ./assets

# Re-validate everything on disk; print catalog summary:
lottie-harvest validate --out ./assets
lottie-harvest catalog  --out ./assets --full
```

Options (`search`/`browse`/`harvest`/`pull`): `--format dotLottie|json|both`,
`--concurrency N`, `--thumbs` (also grab PNG previews), `--out`, `--catalog`.

### Formats
- **dotLottie** — `.lottie` zip containers (default; smallest, richest).
- **json** — raw Lottie/bodymovin JSON. If only a dotLottie URL exists, the body
  is extracted out of the zip automatically.
- **both** — store the dotLottie **and** the JSON (native `jsonUrl` when known,
  otherwise extracted from the zip).

### Output layout
```
<out>/
  catalog.jsonl                      # resumable, append-only log (1 entry/line)
  lottiefilesV2/<uuid>.lottie
  lottiefilesV2/<uuid>.json
  lottiefilesPackages/<lfid>.json
```
Re-runs skip anything already present in the catalog (kind-qualified identity),
so harvesting is **idempotent and resumable**.

## Architecture

```
GraphQLSearcher  ──►  AssetDiscovery.classify/dedupe  ──►  Harvester.pull
(graphql.lottie-       (pure: URL → LottieAsset)            (group by uuid,
 files.com)                                               plan per format,
                                                          download → validate
PageFetcher (chrome/    ──►  (same pipeline, for HTML)       → store → catalog)
 static), or
 pull --from urls.txt
```

- **`GraphQLSearcher`** — primary discovery: keyword search + curated/popular/
  recent/featured, cursor-paginated. Fans each animation node into lottie/json/
  image variants sharing the `uuid` identity.
- **`AssetDiscovery`** — pure regex classify + dedupe. Source-aware
  (`lottiefilesV2` / `lottiefilesPackages` / `lottieHost` / `iconscout`).
- **`LottieValidator`** — JSON (tolerant bodymovin parse + summary), dotLottie
  (zip magic), image (PNG/JPEG/GIF/WEBP magic).
- **`Downloader`** — actor + `AsyncSemaphore`; bounded concurrent CDN fetches.
- **`Storage`** — atomic writes + dotLottie extraction (temp dir, no clutter).
- **`Catalog`** — actor-backed JSONL; resumability keyed on `kind:animationId`.

## Browser fallback (browsermcp / headless Chrome)

Not needed for LottieFiles (GraphQL covers it), but kept for other walled sources:

```bash
# Headless Chrome dump → extract asset URLs → pull (best-effort vs Cloudflare):
lottie-harvest harvest "https://lottiefiles.com/free-animations" --format dotLottie

# Reliable path: harvest URLs in your real browser (browsermcp), save to urls.txt,
# then download from the open CDN:
lottie-harvest pull --from urls.txt --format dotLottie
```

`Scripts/discover-chrome.sh` wraps the headless-dump step for ad-hoc pages.

### browsermcp (optional)
If you want to drive discovery from your real Chrome session (passes Cloudflare
reliably), add this MCP server and have it collect asset URLs into `urls.txt`,
then `pull --from urls.txt`:
```json
{ "mcpServers": { "browsermcp": { "command": "npx", "args": ["@browsermcp/mcp@latest"] } } }
```
