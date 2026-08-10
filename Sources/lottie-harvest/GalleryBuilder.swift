import Foundation
import LottieHarvestCore

/// Builds a self-contained, static HTML gallery from harvested catalog entries.
///
/// Cards are baked in at generation time (no server needed → works on GitHub
/// Pages). Lottie players lazy-load via IntersectionObserver so a few hundred
/// animations don't all fetch on open. The player `src` points at the open
/// LottieFiles asset CDN, so the gallery is metadata-light.
enum GalleryBuilder {

    struct Card: Sendable {
        let id: String
        let name: String
        let author: String?
        let downloads: Int?
        let pageURL: URL?
        let lottieURL: URL?
        let jsonURL: URL?
        let playerURL: URL
        let playerIsDotLottie: Bool
    }

    static func cards(from entries: [CatalogEntry]) -> [Card] {
        let grouped = Dictionary(grouping: entries.filter { $0.status == .ok }, by: \.animationId)
        return grouped.values.compactMap { group -> Card? in
            let dotLottie = group.first { $0.kind == .dotLottie }
            let json = group.first { $0.kind == .json }
            let meta = (dotLottie ?? json ?? group.first)?.meta
            let primary = dotLottie ?? json ?? group.first
            guard let primary else { return nil }
            // Prefer JSON for the player (lottie-player renders .json everywhere);
            // fall back to the dotLottie URL with dotlottie-player.
            let useJSON = json != nil
            let playerURL = (useJSON ? json?.url : dotLottie?.url) ?? primary.url
            return Card(
                id: primary.animationId,
                name: meta?.name ?? primary.stem,
                author: meta?.author,
                downloads: meta?.downloads,
                pageURL: meta?.pageURL,
                lottieURL: dotLottie?.url,
                jsonURL: json?.url,
                playerURL: playerURL,
                playerIsDotLottie: !useJSON
            )
        }
        .sorted { ($0.downloads ?? -1) > ($1.downloads ?? -1) }
    }

    static func html(title: String, cards: [Card]) -> String {
        let cardsHTML = cards.map { card(for: $0) }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <script src="https://unpkg.com/@lottiefiles/lottie-player@latest/dist/lottie-player.js"></script>
        <script src="https://unpkg.com/@dotlottie/lottie-player@latest/dist/dotlottie-player.js"></script>
        <style>
          :root { --bg:#0b0d10; --panel:#14181d; --ink:#e6e9ee; --dim:#8b94a1; --accent:#7c5cff; }
          * { box-sizing:border-box; }
          body { margin:0; background:var(--bg); color:var(--ink);
                 font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif; }
          header { position:sticky; top:0; z-index:5; backdrop-filter:blur(12px);
                   background:rgba(11,13,16,.78); border-bottom:1px solid #232831; padding:16px 20px; }
          header h1 { margin:0; font-size:18px; letter-spacing:.2px; }
          header .sub { color:var(--dim); font-size:13px; margin-top:3px; }
          header input { margin-top:12px; width:100%; max-width:520px; padding:10px 14px;
                         border-radius:10px; border:1px solid #2a313c; background:#0f1216; color:var(--ink); font-size:14px; }
          main { display:grid; grid-template-columns:repeat(auto-fill,minmax(220px,1fr));
                 gap:14px; padding:18px; max-width:1400px; margin:0 auto; }
          .card { background:var(--panel); border:1px solid #232831; border-radius:14px; overflow:hidden;
                  display:flex; flex-direction:column; }
          .card.hide { display:none; }
          .player { aspect-ratio:1/1; display:grid; place-items:center; background:
                    radial-gradient(120% 120% at 50% 0%, #1a2028, #10141a); }
          .player lottie-player, .player dotlottie-player { width:72%; height:72%; }
          .meta { padding:11px 13px 8px; }
          .name { font-size:13.5px; font-weight:600; line-height:1.25; overflow:hidden;
                  text-overflow:ellipsis; white-space:nowrap; }
          .author { color:var(--dim); font-size:11.5px; margin-top:2px;
                    overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
          .stats { color:var(--dim); font-size:11px; margin-top:6px; }
          .links { display:flex; gap:6px; padding:0 13px 13px; margin-top:auto; flex-wrap:wrap; }
          .links a { font-size:11px; padding:5px 9px; border-radius:8px; text-decoration:none;
                     color:var(--ink); background:#1c222b; border:1px solid #283039; }
          .links a:hover { border-color:var(--accent); color:#fff; }
          footer { text-align:center; color:var(--dim); font-size:12px; padding:30px 16px 50px; }
          footer a { color:var(--dim); }
        </style>
        </head>
        <body>
        <header>
          <h1>\(escape(title))</h1>
          <div class="sub" id="count">\(cards.count) animations · rendered live from the LottieFiles asset CDN</div>
          <input id="q" type="search" placeholder="Filter by name or author…" autocomplete="off">
        </header>
        <main id="grid">
        \(cardsHTML)
        </main>
        <footer>Generated by <a href="https://github.com/Ripnrip/lottie-harvest">lottie-harvest</a> ·
                animations © their respective authors on LottieFiles</footer>
        <script>
          // Lazy-load players when they scroll into view.
          const io = new IntersectionObserver((es) => {
            es.forEach(e => {
              if (!e.isIntersecting) return;
              const el = e.target;
              if (!el.hasAttribute('src')) el.setAttribute('src', el.dataset.src);
              io.unobserve(el);
            });
          }, { rootMargin: '300px' });
          document.querySelectorAll('[data-src]').forEach(el => io.observe(el));
          // Filter.
          const grid = document.getElementById('grid');
          const q = document.getElementById('q');
          const count = document.getElementById('count');
          const total = \(cards.count);
          q.addEventListener('input', () => {
            const t = q.value.trim().toLowerCase();
            let shown = 0;
            grid.querySelectorAll('.card').forEach(c => {
              const hay = (c.dataset.name + ' ' + c.dataset.author).toLowerCase();
              const ok = !t || hay.includes(t);
              c.classList.toggle('hide', !ok); if (ok) shown++;
            });
            count.textContent = shown + ' / ' + total + ' animations · rendered live from the LottieFiles asset CDN';
          });
        </script>
        </body>
        </html>
        """
    }

    private static func card(for c: Card) -> String {
        let tag = c.playerIsDotLottie ? "dotlottie-player" : "lottie-player"
        let player = """
        <\(tag) data-src="\(c.playerURL.absoluteString)" background="transparent" autoplay loop speed="1"></\(tag)>
        """
        let author = c.author.map { "<div class=\"author\">by \(escape($0))</div>" } ?? ""
        let stats = c.downloads.map { "<div class=\"stats\">⬇ \($0) downloads</div>" } ?? ""
        var links: [String] = []
        if let page = c.pageURL { links.append("<a href=\"\(page.absoluteString)\" target=\"_blank\" rel=\"noopener\">Page</a>") }
        if let l = c.lottieURL { links.append("<a href=\"\(l.absoluteString)\" target=\"_blank\" rel=\"noopener\">.lottie</a>") }
        if let j = c.jsonURL { links.append("<a href=\"\(j.absoluteString)\" target=\"_blank\" rel=\"noopener\">.json</a>") }
        return """
        <div class="card" data-name="\(escape(c.name))" data-author="\(escape(c.author ?? ""))">
          <div class="player">\(player)</div>
          <div class="meta">
            <div class="name">\(escape(c.name))</div>
            \(author)\(stats)
          </div>
          <div class="links">\(links.joined(separator: ""))</div>
        </div>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
