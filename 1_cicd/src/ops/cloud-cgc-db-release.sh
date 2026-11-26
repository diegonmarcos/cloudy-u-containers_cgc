#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-release.sh — publish ONE repo's cgc index (octocode LanceDB)
#  as a GitHub release, the second channel next to its GHCR image (#1940).
#
#  Runs at the end of a cgc-db-index.yml matrix job, after the index steps
#  pushed <image_prefix><pkg>:<tag>. Mirrors exactly what is served: the image
#  is pulled back from GHCR and its /octocode-db is what gets released.
#
#  Config: .per_repo_publish.github_release in
#  a_solutions/user-ai_cloud-cgc-pub-mcp/build.json (cloud-u-containers).
#
#  Release layout, one rolling release per repo on the CALLING repository:
#    tag   <tag_prefix><pkg>            e.g. cgc-db-cloud-data
#    <asset_base>.<ext>.NNN             parts, each <= part_size_mib MiB (< 2 GiB cap)
#    SHA256SUMS                         sha256 of every part + of the whole archive
#    manifest.json                      written LAST: image digest, parts, sizes
#  An image whose digest equals the released manifest's is not re-uploaded.
#
#  Visibility gate: a PRIVATE repo's index is released only on a PRIVATE caller.
#  The indexed repo's visibility comes from the package script's own resolver
#  (repo_map -> gh repo view), fail-safe private.
#
#  Proof before success: the local parts are decompressed and compared with the
#  pulled DB (tar --compare plus a file count), and every uploaded asset's
#  digest reported by GitHub must equal SHA256SUMS.
#
#  Env: CGC_INDEX_REPOS (one local name), CGC_SURFACE (pub|pvt), GITHUB_REPOSITORY,
#       GITHUB_SHA, GH_TOKEN/GITHUB_TOKEN, RUNNER_TEMP. Optional CGC_BUILD_JSON.
#  Sourced with CGC_REL_SOURCE_ONLY=1 it defines the functions and runs nothing.
# ──────────────────────────────────────────────────────────────────────────
set -eu

REL_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")
[ -n "${CGC_REL_OPS_DIR:-}" ] && REL_HERE="$CGC_REL_OPS_DIR"

# The visibility helpers live in the package script; source them, run nothing.
# shellcheck disable=SC1091
CGC_PKG_SOURCE_ONLY=1 . "$REL_HERE/cloud-cgc-db-package.sh"
set -eu

rel_log() { echo "[cgc-db-release] $*"; }
rel_err() { echo "::error::[cgc-db-release] $*"; }

# Same local-name -> package-name fold as the GHCR preflight in cgc-db-index.yml.
rel_pkg_suffix() { # $1=LOCAL_NAME
  printf %s "$1" | tr A-Z a-z | sed -E 's/[._-]{2,}/-/g; s/^[._-]+//'
}

rel_cfg() { # $1=jq path under .per_repo_publish.github_release, $2=default
  _rc_bj=$(resolve_bj) || { printf '%s\n' "$2"; return 0; }
  _rc_v=$(jq -r ".per_repo_publish.github_release.$1 // empty" "$_rc_bj" 2>/dev/null || echo "")
  [ -n "$_rc_v" ] && printf '%s\n' "$_rc_v" || printf '%s\n' "$2"
}

# rc 0 iff the release channel is enabled for this surface.
rel_enabled() { # $1=SURFACE
  _re_bj=$(resolve_bj) || return 1
  [ "$(jq -r '.per_repo_publish.github_release.enabled // false' "$_re_bj")" = "true" ] || return 1
  jq -e --arg s "$1" '(.per_repo_publish.github_release.surfaces // []) | index($s) != null' "$_re_bj" >/dev/null
}

# Gate: rc 0 = may release on $GITHUB_REPOSITORY. Private index -> private caller only.
rel_gate() { # $1=PKG $2=LOCAL_NAME
  resolve_repo_desired_visibility "$1" "$2"
  if [ "$_rdv_desired" = "public" ]; then
    return 0
  fi
  if caller_is_private; then
    return 0
  fi
  rel_err "$1: the indexed repo is private (or its visibility is unknown) and $GITHUB_REPOSITORY is not provably private — refusing to release it"
  return 1
}

rel_part_bytes() { # stdout: part size in bytes, capped below GitHub's 2 GiB asset limit
  _rpb=$(rel_cfg part_size_mib 1900)
  case "$_rpb" in ''|*[!0-9]*) _rpb=1900 ;; esac
  [ "$_rpb" -ge 1 ] || _rpb=1900
  [ "$_rpb" -le 2000 ] || _rpb=2000
  echo $(( _rpb * 1048576 ))
}

# Compression actually used: the declared one when the runner has it, else gzip.
rel_compression() {
  _rcm=$(rel_cfg compression zstd)
  if [ "$_rcm" = "zstd" ] && ! command -v zstd >/dev/null 2>&1; then
    echo "::warning::[cgc-db-release] zstd is not installed on this runner — falling back to gzip (recorded in manifest.json)" >&2
    _rcm=gzip
  fi
  case "$_rcm" in zstd|gzip) echo "$_rcm" ;; *) echo gzip ;; esac
}

rel_ext() { # $1=compression
  case "$1" in zstd) echo zst ;; *) echo gz ;; esac
}

rel_compress() { # $1=compression ; stdin -> stdout
  case "$1" in
    zstd) zstd -q -T0 "-$(rel_cfg zstd_level 3)" -c ;;
    *)    gzip -c -6 ;;
  esac
}

rel_decompress() { # $1=compression ; stdin -> stdout
  case "$1" in
    zstd) zstd -q -d -c ;;
    *)    gzip -d -c ;;
  esac
}

# Pack DBDIR (the directory named octocode-db) into OUT/<base>.<ext>.NNN parts,
# SHA256SUMS and a manifest body (manifest.json written by rel_manifest).
# Sets REL_PARTS (space separated basenames), REL_ARCHIVE_SHA, REL_ARCHIVE_BYTES.
rel_pack() { # $1=DBDIR $2=OUTDIR $3=compression
  _rp_db="$1"; _rp_out="$2"; _rp_c="$3"
  [ -d "$_rp_db" ] || { rel_err "no DB directory at $_rp_db"; return 1; }
  mkdir -p "$_rp_out"
  _rp_name="$(rel_cfg asset_base octocode-db.tar).$(rel_ext "$_rp_c")"
  _rp_parent=$(dirname "$_rp_db"); _rp_leaf=$(basename "$_rp_db")
  tar cf - -C "$_rp_parent" "$_rp_leaf" | rel_compress "$_rp_c" \
    | split -b "$(rel_part_bytes)" -d -a 3 - "$_rp_out/$_rp_name."
  REL_PARTS=$(cd "$_rp_out" && ls "$_rp_name".[0-9][0-9][0-9] | tr '\n' ' ' | sed 's/ $//')
  [ -n "$REL_PARTS" ] || { rel_err "packing produced no parts"; return 1; }
  # shellcheck disable=SC2086
  REL_ARCHIVE_SHA=$(cd "$_rp_out" && cat $REL_PARTS | sha256sum | cut -d' ' -f1)
  # shellcheck disable=SC2086
  REL_ARCHIVE_BYTES=$(cd "$_rp_out" && cat $REL_PARTS | wc -c | tr -d ' ')
  # shellcheck disable=SC2086
  ( cd "$_rp_out" && sha256sum $REL_PARTS > SHA256SUMS && printf '%s  %s\n' "$REL_ARCHIVE_SHA" "$_rp_name" >> SHA256SUMS )
}

# Round trip: the parts decompress to exactly DBDIR (content, sizes, modes, mtimes)
# and to the same number of entries.
rel_verify_local() { # $1=DBDIR $2=OUTDIR $3=compression
  _rv_db="$1"; _rv_out="$2"; _rv_c="$3"
  _rv_parent=$(dirname "$_rv_db")
  # The whole-archive line names a file that is never written; check the parts only.
  # shellcheck disable=SC2086
  ( cd "$_rv_out" && grep -v " $(rel_cfg asset_base octocode-db.tar).$(rel_ext "$_rv_c")\$" SHA256SUMS | sha256sum -c --quiet ) \
    || { rel_err "part checksums do not match SHA256SUMS"; return 1; }
  # shellcheck disable=SC2086
  ( cd "$_rv_out" && cat $REL_PARTS ) | rel_decompress "$_rv_c" | tar --compare -f - -C "$_rv_parent" >/dev/null \
    || { rel_err "the released archive does not reproduce the DB (tar --compare)"; return 1; }
  # shellcheck disable=SC2086
  _rv_n_tar=$( ( cd "$_rv_out" && cat $REL_PARTS ) | rel_decompress "$_rv_c" | tar tf - | sed 's#/$##' | sort -u | wc -l | tr -d ' ')
  _rv_n_fs=$( cd "$_rv_parent" && find "$(basename "$_rv_db")" | sort -u | wc -l | tr -d ' ')
  [ "$_rv_n_tar" = "$_rv_n_fs" ] \
    || { rel_err "the archive holds $_rv_n_tar entries, the DB $_rv_n_fs"; return 1; }
  REL_DB_ENTRIES="$_rv_n_fs"
}

rel_manifest() { # $1=OUTDIR $2=PKG $3=LOCAL_NAME $4=IMAGE $5=DIGEST $6=compression $7=DBDIR
  _rm_out="$1"
  _rm_parts=$(cd "$_rm_out" && for p in $REL_PARTS; do
      printf '{"name":"%s","bytes":%s,"sha256":"%s"}\n' "$p" "$(wc -c < "$p" | tr -d ' ')" "$(sha256sum "$p" | cut -d' ' -f1)"
    done | jq -s .)
  _rm_dbbytes=$(du -sb "$7" 2>/dev/null | cut -f1 || echo 0)
  jq -n \
    --arg pkg "$2" --arg repo "$3" --arg image "$4" --arg digest "$5" --arg comp "$6" \
    --arg sha "$REL_ARCHIVE_SHA" --argjson bytes "$REL_ARCHIVE_BYTES" --argjson parts "$_rm_parts" \
    --argjson entries "${REL_DB_ENTRIES:-0}" --argjson dbbytes "${_rm_dbbytes:-0}" \
    --arg octo "$(jq -r '.runtime.octocode.version // empty' "$(resolve_bj)" 2>/dev/null || echo "")" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg caller "${GITHUB_REPOSITORY:-}" \
    --arg run "${GITHUB_RUN_ID:-}" --arg cgc_sha "${GITHUB_SHA:-}" \
    '{schema:1, format:"octocode LanceDB (Lance tables code_blocks, file_metadata, graphrag_nodes, graphrag_relationships) under octocode-db/",
      package:$pkg, local_name:$repo, image:$image, image_digest:$digest, octocode_version:$octo,
      compression:$comp, archive:{sha256:$sha, bytes:$bytes}, parts:$parts,
      db:{entries:$entries, bytes:$dbbytes},
      restore:"cat the parts in name order | decompress | tar x  (or: sh 1_cicd/src/ops/cloud-cgc-db-release-restore.sh <tag> <dir>)",
      created:$created, caller:$caller, run_id:$run, commit:$cgc_sha}' > "$_rm_out/manifest.json"
}

# Download one asset of a release through the REST API (gh release download goes
# through GraphQL, which not every token or session may use). rc 1 when absent.
rel_asset_get() { # $1=REPO $2=TAG $3=ASSET_NAME $4=DEST_FILE
  _rag_id=$(gh api "repos/$1/releases/tags/$2" --jq ".assets[] | select(.name==\"$3\") | .id" 2>/dev/null) || return 1
  [ -n "$_rag_id" ] || return 1
  gh api -H 'Accept: application/octet-stream' "repos/$1/releases/assets/$_rag_id" > "$4" 2>/dev/null
}

# Digest of the image the existing release was cut from ("" when none).
rel_released_digest() { # $1=TAG
  _rrd_dir=$(mktemp -d)
  if rel_asset_get "$GITHUB_REPOSITORY" "$1" manifest.json "$_rrd_dir/manifest.json"; then
    jq -r '.image_digest // empty' "$_rrd_dir/manifest.json" 2>/dev/null || true
  fi
  rm -rf "$_rrd_dir"
}

# Create the release when missing, upload parts + SHA256SUMS, manifest.json last,
# then drop assets that are no longer part of the set (a shrunk DB has fewer parts).
rel_publish() { # $1=TAG $2=OUTDIR $3=PKG
  _rpu_tag="$1"; _rpu_out="$2"
  if ! gh release view "$_rpu_tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    gh release create "$_rpu_tag" -R "$GITHUB_REPOSITORY" --target "${GITHUB_SHA:-main}" --latest=false \
      --title "cgc index: $3" \
      --notes "Rolling release of the cgc code index of $3 (octocode LanceDB). Same content as the GHCR image; see manifest.json. Updated by cgc-db-index.yml (#1940)." >/dev/null
    rel_log "created release $_rpu_tag on $GITHUB_REPOSITORY"
  fi
  # shellcheck disable=SC2086
  ( cd "$_rpu_out" && gh release upload "$_rpu_tag" -R "$GITHUB_REPOSITORY" --clobber $REL_PARTS SHA256SUMS ) >/dev/null
  ( cd "$_rpu_out" && gh release upload "$_rpu_tag" -R "$GITHUB_REPOSITORY" --clobber manifest.json ) >/dev/null
  _rpu_keep=" $REL_PARTS SHA256SUMS manifest.json "
  for _rpu_a in $(gh release view "$_rpu_tag" -R "$GITHUB_REPOSITORY" --json assets -q '.assets[].name'); do
    case "$_rpu_keep" in
      *" $_rpu_a "*) : ;;
      *) gh release delete-asset "$_rpu_tag" "$_rpu_a" -R "$GITHUB_REPOSITORY" -y >/dev/null && rel_log "removed stale asset $_rpu_a" ;;
    esac
  done
}

# Every asset of the release must carry the sha256 SHA256SUMS / manifest.json declare.
rel_verify_remote() { # $1=TAG $2=OUTDIR
  _rvr_json=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$1" --jq '[.assets[] | {name, digest, size}]') \
    || { rel_err "cannot read release $1 back"; return 1; }
  for _rvr_f in $REL_PARTS SHA256SUMS manifest.json; do
    _rvr_want=$(sha256sum "$2/$_rvr_f" | cut -d' ' -f1)
    _rvr_got=$(printf '%s' "$_rvr_json" | jq -r --arg n "$_rvr_f" '.[] | select(.name==$n) | .digest // empty')
    if [ -z "$_rvr_got" ]; then
      # Older API answers carry no digest: download that asset and hash it.
      _rvr_d=$(mktemp -d)
      rel_asset_get "$GITHUB_REPOSITORY" "$1" "$_rvr_f" "$_rvr_d/$_rvr_f" \
        || { rm -rf "$_rvr_d"; rel_err "asset $_rvr_f missing from release $1"; return 1; }
      _rvr_got="sha256:$(sha256sum "$_rvr_d/$_rvr_f" | cut -d' ' -f1)"
      rm -rf "$_rvr_d"
    fi
    [ "$_rvr_got" = "sha256:$_rvr_want" ] \
      || { rel_err "release asset $_rvr_f has digest $_rvr_got, expected sha256:$_rvr_want"; return 1; }
  done
  _rvr_n=$(printf '%s' "$_rvr_json" | jq 'length')
  _rvr_w=$(( $(echo $REL_PARTS | wc -w) + 2 ))
  [ "$_rvr_n" = "$_rvr_w" ] || { rel_err "release $1 holds $_rvr_n assets, expected $_rvr_w"; return 1; }
}

# Extract the served image's /octocode-db into DEST/octocode-db; prints the image digest.
rel_extract() { # $1=IMAGE:TAG $2=DEST
  docker pull -q "$1" >/dev/null
  _rx_digest=$(docker inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null | sed 's/.*@//')
  _rx_cid=$(docker create "$1" true)
  mkdir -p "$2"
  docker cp "$_rx_cid:/octocode-db" "$2/octocode-db" >/dev/null
  docker rm "$_rx_cid" >/dev/null 2>&1 || true
  docker rmi "$1" >/dev/null 2>&1 || true
  printf '%s\n' "$_rx_digest"
}

rel_main() {
  _m_local="${CGC_INDEX_REPOS:?CGC_INDEX_REPOS (one repo) is required}"
  case "$_m_local" in *" "*|*,*) rel_err "one repo per job, got '$_m_local'"; return 1 ;; esac
  _m_surface="${CGC_SURFACE:-pub}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if ! rel_enabled "$_m_surface"; then
    rel_log "release channel disabled for surface $_m_surface in build.json — nothing to do"
    return 0
  fi
  _m_bj=$(resolve_bj) || { rel_err "build.json not found"; return 1; }
  _m_prefix=$(jq -r '.per_repo_publish.image_prefix' "$_m_bj")
  _m_imgtag=$(jq -r '.per_repo_publish.tag // "latest"' "$_m_bj")
  _m_suffix=$(rel_pkg_suffix "$_m_local")
  _m_pkg="${_m_prefix##*/}$_m_suffix"
  _m_image="$_m_prefix$_m_suffix:$_m_imgtag"
  _m_tag="$(rel_cfg tag_prefix cgc-db-)$_m_suffix"

  rel_gate "$_m_pkg" "$_m_local" || return 1

  _m_work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cgc-rel.XXXXXX")
  # Registry login for private images, token on stdin into a throwaway config.
  export DOCKER_CONFIG="$_m_work/docker"; mkdir -p "$DOCKER_CONFIG"
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-x-access-token}" --password-stdin >/dev/null 2>&1 || true
  fi
  _m_digest=$(rel_extract "$_m_image" "$_m_work/src") \
    || { rel_err "$_m_image could not be pulled — nothing published to release"; rm -rf "$_m_work"; return 1; }
  docker logout ghcr.io >/dev/null 2>&1 || true

  if [ -n "$_m_digest" ] && [ "$(rel_released_digest "$_m_tag")" = "$_m_digest" ]; then
    rel_log "$_m_tag already holds image $_m_digest — unchanged, not re-uploaded"
    rm -rf "$_m_work"; return 0
  fi

  _m_comp=$(rel_compression)
  rel_pack "$_m_work/src/octocode-db" "$_m_work/out" "$_m_comp"
  rel_verify_local "$_m_work/src/octocode-db" "$_m_work/out" "$_m_comp"
  rel_manifest "$_m_work/out" "$_m_pkg" "$_m_local" "$_m_image" "$_m_digest" "$_m_comp" "$_m_work/src/octocode-db"
  rm -rf "$_m_work/src"
  rel_publish "$_m_tag" "$_m_work/out" "$_m_pkg"
  rel_verify_remote "$_m_tag" "$_m_work/out"
  rel_log "released $_m_image ($_m_digest) as $GITHUB_REPOSITORY@$_m_tag: $(echo $REL_PARTS | wc -w) part(s), $REL_ARCHIVE_BYTES bytes, $REL_DB_ENTRIES DB entries, compression $_m_comp"
  rm -rf "$_m_work"
}

[ "${CGC_REL_SOURCE_ONLY:-0}" = "1" ] || rel_main "$@"
