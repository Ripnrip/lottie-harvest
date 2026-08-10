#!/usr/bin/env bash
# discover-chrome.sh — best-effort headless-Chrome discovery for ad-hoc pages.
#
# Renders each seed URL with headless Google Chrome (--dump-dom), extracts every
# Lottie asset URL, and prints them one-per-line (ready for: pull --from urls.txt).
#
# NOTE: For LottieFiles, prefer `lottie-harvest search "<q>"` / `browse` — they go
# through the open GraphQL API and never hit Cloudflare. Use this script only for
# other walled sources where a real-browser dump is the discovery path.

set -euo pipefail

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
BUDGET="${BUDGET:-12000}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <page-url> [<page-url> ...]" >&2
  exit 64
fi

for url in "$@"; do
  echo "# $url" >&2
  "$CHROME" --headless=new --disable-gpu --no-sandbox --no-first-run \
    --no-default-browser-check --user-agent="$UA" \
    --virtual-time-budget="$BUDGET" --dump-dom "$url" 2>/dev/null
done \
  | grep -oE 'https?://(assets-v2\.lottiefiles\.com/a/[0-9A-Fa-f-]{36}/[A-Za-z0-9_-]+\.(lottie|json|png)|assets[0-9]*\.lottiefiles\.com/packages/[A-Za-z0-9_]+\.(lottie|json)|lottie\.host/[0-9A-Fa-f-]{36}/[A-Za-z0-9_.-]+\.(lottie|json))' \
  | sort -u
