#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-release-restore.sh — restore one cgc index (octocode LanceDB)
#  from its GitHub release (#1940), the counterpart of cloud-cgc-db-release.sh.
#
#  Usage: sh cloud-cgc-db-release-restore.sh <tag> <dest-dir> [owner/repo]
#    <tag>         e.g. cgc-db-cloud-data
#    <dest-dir>    receives octocode-db/ (must not already hold one)
#    [owner/repo]  release repository, default diegonmarcos/cloudy-u-containers_cgc
#
#  Downloads manifest.json, SHA256SUMS and the parts, checks every checksum
#  (parts and the whole archive) before extracting anything, then unpacks.
#  Needs gh (GH_TOKEN for a private repository), sha256sum, tar, zstd or gzip.
# ──────────────────────────────────────────────────────────────────────────
set -eu
TAG="${1:?usage: $0 <tag> <dest-dir> [owner/repo]}"
DEST="${2:?usage: $0 <tag> <dest-dir> [owner/repo]}"
REPO="${3:-diegonmarcos/cloudy-u-containers_cgc}"

[ ! -e "$DEST/octocode-db" ] || { echo "::error::$DEST/octocode-db already exists — refusing to overwrite"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

gh release download "$TAG" -R "$REPO" -D "$WORK" >/dev/null
[ -f "$WORK/manifest.json" ] && [ -f "$WORK/SHA256SUMS" ] \
  || { echo "::error::release $REPO@$TAG has no manifest.json/SHA256SUMS"; exit 1; }

COMP=$(jq -r '.compression' "$WORK/manifest.json")
ARCH_SHA=$(jq -r '.archive.sha256' "$WORK/manifest.json")
PARTS=$(jq -r '.parts[].name' "$WORK/manifest.json" | sort)
[ -n "$PARTS" ] || { echo "::error::manifest.json lists no parts"; exit 1; }

cd "$WORK"
for p in $PARTS; do
  grep -q "  $p\$" SHA256SUMS || { echo "::error::$p is not in SHA256SUMS"; exit 1; }
done
# shellcheck disable=SC2086
grep -E "  ($(echo $PARTS | tr ' ' '|'))\$" SHA256SUMS | sha256sum -c --quiet \
  || { echo "::error::part checksum mismatch"; exit 1; }
# shellcheck disable=SC2086
GOT=$(cat $PARTS | sha256sum | cut -d' ' -f1)
[ "$GOT" = "$ARCH_SHA" ] || { echo "::error::archive sha256 $GOT, manifest says $ARCH_SHA"; exit 1; }

case "$COMP" in
  zstd) DEC="zstd -q -d -c" ;;
  gzip) DEC="gzip -d -c" ;;
  *) echo "::error::unknown compression '$COMP'"; exit 1 ;;
esac
mkdir -p "$DEST"
# shellcheck disable=SC2086
cat $PARTS | $DEC | tar xf - -C "$DEST"
echo "[cgc-db-release-restore] $REPO@$TAG -> $DEST/octocode-db ($(jq -r '.db.entries' manifest.json) entries, image $(jq -r '.image_digest' manifest.json))"
