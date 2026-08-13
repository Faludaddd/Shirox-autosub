#!/usr/bin/env bash
# Regenerates Shirox/Resources/restricted_hosts.txt from a content-restricted
# host list. Uses the focused list (not the unified StevenBlack list) so we
# don't block ad/malware/CDN hosts that legitimate streaming modules may rely
# on.
set -euo pipefail
SRC="https://raw.githubusercontent.com/Sinfonietta/hostfiles/master/pornography-hosts"
OUT="$(dirname "$0")/../Shirox/Resources/restricted_hosts.txt"
mkdir -p "$(dirname "$OUT")"
{
  echo "# Restricted host blocklist for Shirox."
  echo "# Source: $SRC"
  echo "# Regenerate with scripts/fetch_restricted_hosts.sh"
  curl -fsSL "$SRC"
} > "$OUT"
echo "Wrote $(grep -vc '^#' "$OUT") host lines to $OUT"
