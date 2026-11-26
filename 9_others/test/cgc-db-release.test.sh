#!/usr/bin/env bash
# Tester for the cgc GitHub release channel (#1940):
#   cloud-cgc-db-release.sh (publish) + cloud-cgc-db-release-restore.sh (restore).
#
# Runs the REAL scripts against stub `gh` and `docker` on PATH: the stub gh keeps
# releases as directories under $STORE (assets, digests like the REST API reports
# them), the stub docker "pulls" a fixture DB directory. Nothing leaves the box.
#
# Cases: publish + byte-for-byte restore; parts below the cap; unchanged digest is
# not re-uploaded; a shrunk DB drops stale parts; private index on a public caller
# refused (and unknown visibility likewise); private index on a private caller
# released; a corrupted upload fails the run; disabled config is a no-op; a
# tampered part fails the restore; the real config and the workflow wiring.
# Mutations: each guard is broken in a copy of the script and must turn a case red.
set -uo pipefail

REPO_ROOT="$(_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
OPS="$REPO_ROOT/1_cicd/src/ops"
REL_SH="$OPS/cloud-cgc-db-release.sh"
RESTORE_SH="$OPS/cloud-cgc-db-release-restore.sh"
for f in "$REL_SH" "$RESTORE_SH" "$OPS/cloud-cgc-db-package.sh"; do
  [ -f "$f" ] || { echo "::error::missing $f"; exit 1; }
done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

COMP=gzip; command -v zstd >/dev/null 2>&1 && COMP=zstd

# ── fixture build.json ──
mk_bj() { # $1=enabled $2=part_size_mib
  jq -n --argjson en "$1" --argjson ps "$2" --arg comp "$COMP" '{
    per_repo_publish: {image_prefix:"ghcr.io/diegonmarcos/cgc-db-", tag:"latest",
      github_release:{enabled:$en, surfaces:["pub","pvt"], tag_prefix:"cgc-db-",
        asset_base:"octocode-db.tar", compression:$comp, zstd_level:3, part_size_mib:$ps}},
    runtime: {octocode: {version:"0.22.0",
      repo_map: {"cloud-pubrepo":"cloud-pubrepo", "cloud-pvtrepo":"cloud-pvtrepo"},
      private_repos: ["cloud-pvtrepo"]}}}' > "$W/build.json"
}

# ── fixture DB: a few MiB of incompressible data in a Lance-like layout ──
mk_db() { # $1=dir $2=MiB of data
  rm -rf "$1"; mkdir -p "$1/octocode-db/proj/storage/code_blocks.lance/data" "$1/octocode-db/proj/storage/graphrag_nodes.lance/_versions"
  head -c "$(( $2 * 1048576 ))" /dev/urandom > "$1/octocode-db/proj/storage/code_blocks.lance/data/0.lance"
  printf 'v1\n' > "$1/octocode-db/proj/storage/graphrag_nodes.lance/_versions/1.manifest"
  printf 'cfg\n' > "$1/octocode-db/config.toml"
  chmod 640 "$1/octocode-db/config.toml"
}

# ── stub docker ──
mkdir -p "$W/bin" "$W/store"
cat > "$W/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pull) exit "${FAKE_PULL_RC:-0}" ;;
  inspect) echo "ghcr.io/diegonmarcos/x@${FAKE_DIGEST:-sha256:aaaa}" ;;
  create) echo cid123 ;;
  cp) cp -a "$FAKE_DB_SRC/octocode-db" "$3" ;;
  rm|rmi|login|logout) exit 0 ;;
  *) exit 0 ;;
esac
EOF
# ── stub gh: releases as dirs under $FAKE_STORE/<tag>/ ──
cat > "$W/bin/gh" <<'EOF'
#!/usr/bin/env bash
S="$FAKE_STORE"
# Asset id = "<tag>@<name>" with / replaced, so the octet-stream route can find the file.
digest_json() { # $1=tag
  for f in "$S/$1"/*; do [ -f "$f" ] || continue
    printf '{"id":"%s","name":"%s","digest":"sha256:%s","size":%s}\n' "$1@$(basename "$f")" "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f")"
  done | jq -s '{assets: .}'
}
[ "$1" = "release" ] && [ "$2" = "download" ] && { echo "STUB: gh release download is GraphQL, scripts must use REST" >&2; exit 99; }
if [ "$1" = "api" ] && [ "$2" = "-H" ]; then
  path="$4"; id="${path##*/assets/}"; cat "$S/${id%%@*}/${id#*@}" || exit 1; exit 0
fi
case "$1 $2" in
  "api repos/"*)
    path="$2"; shift 2; q=""; [ "${1:-}" = "--jq" ] && q="$2"
    case "$path" in
      */releases/tags/*) tag="${path##*/}"; [ -d "$S/$tag" ] || exit 1; digest_json "$tag" | jq -r "${q:-.}" ;;
      *) [ "${FAKE_CALLER_PRIVATE:-false}" = "fail" ] && exit 1; echo "${FAKE_CALLER_PRIVATE:-false}" ;;
    esac ;;
  "repo view")
    [ "${FAKE_REPO_PRIVATE:-false}" = "fail" ] && exit 1
    case "$3" in *pvtrepo) echo "${FAKE_REPO_PRIVATE_PVT:-true}" ;; *) echo "${FAKE_REPO_PRIVATE:-false}" ;; esac ;;
  "release view")
    tag="$3"; [ -d "$S/$tag" ] || exit 1
    if printf '%s\n' "$@" | grep -q -- '--json'; then ls "$S/$tag"; fi ;;
  "release create") mkdir -p "$S/$3"; echo "$*" >> "$S/.created" ;;
  "release upload")
    tag="$3"; shift 3
    for a in "$@"; do case "$a" in -R|--clobber) continue ;; esac
      [ -f "$a" ] || continue
      cp "$a" "$S/$tag/$(basename "$a")"
      [ "$(basename "$a")" = "${FAKE_CORRUPT:-none}" ] && printf 'x' >> "$S/$tag/$(basename "$a")"
      echo "$(basename "$a")" >> "$S/.uploads"
    done ;;
  "release delete-asset") rm -f "$S/$3/$4" ;;
  "release download")
    tag="$3"; shift 3; pat="*"; dir="."
    while [ $# -gt 0 ]; do case "$1" in -p) pat="$2"; shift 2 ;; -D) dir="$2"; shift 2 ;; *) shift ;; esac; done
    [ -d "$S/$tag" ] || exit 1
    n=0; for f in "$S/$tag"/$pat; do [ -f "$f" ] && cp "$f" "$dir/" && n=1; done
    [ "$n" = 1 ] || exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$W/bin/docker" "$W/bin/gh"

reset_store() { rm -rf "$W/store"; mkdir -p "$W/store"; }

# run the publish script; $1=local repo, rest = env overrides
run_rel() { # $1=script $2=local repo, then env
  local s="$1" r="$2"; shift 2
  env PATH="$W/bin:$PATH" FAKE_STORE="$W/store" FAKE_DB_SRC="$W/db" CGC_BUILD_JSON="$W/build.json" \
    CGC_REL_OPS_DIR="$(dirname "$s")" CGC_INDEX_REPOS="$r" CGC_SURFACE=pub GITHUB_REPOSITORY=diegonmarcos/cloudy-u-containers_cgc \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GH_TOKEN=stub RUNNER_TEMP="$W" "$@" sh "$s" 2>&1
}
TAG_PUB="cgc-db-cloud-pubrepo"; TAG_PVT="cgc-db-cloud-pvtrepo"

echo "── publish + restore (compression: $COMP) ──"
mk_bj true 1; mk_db "$W/db" 3; reset_store
out=$(run_rel "$REL_SH" cloud-pubrepo FAKE_DIGEST=sha256:d1); rc=$?
[ "$rc" = 0 ] && ok "public index on public caller released" || { bad "publish rc=$rc"; echo "$out" | tail -8; }
nparts=$(ls "$W/store/$TAG_PUB" 2>/dev/null | grep -c '\.[0-9][0-9][0-9]$')
[ "$nparts" -ge 3 ] && ok "3 MiB of incompressible data at 1 MiB parts -> $nparts parts" || bad "expected >=3 parts, got $nparts"
big=$(find "$W/store/$TAG_PUB" -type f -size +1048576c | wc -l)
[ "$big" = 0 ] && ok "every asset is at most part_size_mib" || bad "$big asset(s) above the part size"
[ -f "$W/store/$TAG_PUB/SHA256SUMS" ] && [ -f "$W/store/$TAG_PUB/manifest.json" ] && ok "SHA256SUMS and manifest.json uploaded" || bad "SHA256SUMS/manifest.json missing"
[ "$(tail -1 "$W/store/.uploads")" = "manifest.json" ] && ok "manifest.json is uploaded last" || bad "manifest.json not last"
[ "$(jq -r '.image_digest' "$W/store/$TAG_PUB/manifest.json")" = "sha256:d1" ] && ok "manifest carries the image digest" || bad "manifest image_digest"
[ "$(jq -r '.compression' "$W/store/$TAG_PUB/manifest.json")" = "$COMP" ] && ok "manifest records the compression" || bad "manifest compression"
[ "$(jq '.parts|length' "$W/store/$TAG_PUB/manifest.json")" = "$nparts" ] && ok "manifest lists every part" || bad "manifest parts count"
grep -q -- '--latest=false' "$W/store/.created" && ok "release is never marked the repo's latest" || bad "release create without --latest=false"

out=$(env PATH="$W/bin:$PATH" FAKE_STORE="$W/store" sh "$RESTORE_SH" "$TAG_PUB" "$W/restored" 2>&1); rc=$?
if [ "$rc" = 0 ] && diff -r "$W/db/octocode-db" "$W/restored/octocode-db" >/dev/null; then
  ok "restore from the release reproduces the DB byte for byte"
else bad "restore rc=$rc or content differs"; echo "$out" | tail -5; fi
[ "$(stat -c %a "$W/restored/octocode-db/config.toml")" = 640 ] && ok "restore keeps file modes" || bad "restore lost file modes"
out=$(env PATH="$W/bin:$PATH" FAKE_STORE="$W/store" sh "$RESTORE_SH" "$TAG_PUB" "$W/restored" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "restore refuses to overwrite an existing octocode-db" || bad "restore overwrote (rc=$rc)"

echo "── unchanged image is not re-uploaded ──"
: > "$W/store/.uploads"
out=$(run_rel "$REL_SH" cloud-pubrepo FAKE_DIGEST=sha256:d1); rc=$?
[ "$rc" = 0 ] && grep -q "unchanged, not re-uploaded" <<<"$out" && [ ! -s "$W/store/.uploads" ] \
  && ok "same digest -> no upload" || { bad "same digest re-uploaded (rc=$rc)"; echo "$out" | tail -4; }

echo "── a shrunk DB drops its stale parts ──"
mk_db "$W/db" 1
out=$(run_rel "$REL_SH" cloud-pubrepo FAKE_DIGEST=sha256:d2); rc=$?
n2=$(ls "$W/store/$TAG_PUB" | grep -c '\.[0-9][0-9][0-9]$')
[ "$rc" = 0 ] && [ "$n2" -lt "$nparts" ] && [ "$n2" = "$(jq '.parts|length' "$W/store/$TAG_PUB/manifest.json")" ] \
  && ok "1 MiB DB -> $n2 part(s), stale parts removed" || { bad "stale parts kept (rc=$rc, parts=$n2)"; echo "$out" | tail -4; }
rm -rf "$W/restored"
env PATH="$W/bin:$PATH" FAKE_STORE="$W/store" sh "$RESTORE_SH" "$TAG_PUB" "$W/restored" >/dev/null 2>&1 \
  && diff -r "$W/db/octocode-db" "$W/restored/octocode-db" >/dev/null && ok "restore after the update matches the new DB" || bad "restore after update differs"

echo "── visibility gate ──"
reset_store; mk_db "$W/db" 1
out=$(run_rel "$REL_SH" cloud-pvtrepo FAKE_CALLER_PRIVATE=false); rc=$?
[ "$rc" = 1 ] && [ ! -d "$W/store/$TAG_PVT" ] && grep -q "refusing to release" <<<"$out" \
  && ok "private index on a public caller -> refused, no release" || { bad "private index leaked (rc=$rc)"; echo "$out" | tail -4; }
out=$(run_rel "$REL_SH" cloud-pubrepo FAKE_REPO_PRIVATE=fail FAKE_CALLER_PRIVATE=false); rc=$?
[ "$rc" = 1 ] && [ ! -d "$W/store/$TAG_PUB" ] && ok "unknown repo visibility on a public caller -> refused" || bad "unknown visibility released (rc=$rc)"
out=$(run_rel "$REL_SH" cloud-pvtrepo FAKE_CALLER_PRIVATE=fail); rc=$?
[ "$rc" = 1 ] && [ ! -d "$W/store/$TAG_PVT" ] && ok "caller visibility unreadable -> refused" || bad "unreadable caller released (rc=$rc)"
out=$(run_rel "$REL_SH" cloud-pvtrepo FAKE_CALLER_PRIVATE=true CGC_SURFACE=pvt GITHUB_REPOSITORY=diegonmarcos/cloud-me-pvt-cgc); rc=$?
[ "$rc" = 0 ] && [ -f "$W/store/$TAG_PVT/manifest.json" ] && ok "private index on a private caller -> released" || { bad "private caller refused (rc=$rc)"; echo "$out" | tail -4; }

echo "── a corrupted upload fails the run ──"
reset_store
out=$(run_rel "$REL_SH" cloud-pubrepo FAKE_CORRUPT=octocode-db.tar.$([ "$COMP" = zstd ] && echo zst || echo gz).000); rc=$?
[ "$rc" != 0 ] && grep -q "has digest" <<<"$out" && ok "uploaded part with a wrong digest -> run fails" || { bad "corrupt upload passed (rc=$rc)"; echo "$out" | tail -4; }

echo "── tampered part fails the restore ──"
reset_store; run_rel "$REL_SH" cloud-pubrepo >/dev/null
p0=$(ls "$W/store/$TAG_PUB" | grep '\.000$'); printf 'x' >> "$W/store/$TAG_PUB/$p0"
rm -rf "$W/restored"
out=$(env PATH="$W/bin:$PATH" FAKE_STORE="$W/store" sh "$RESTORE_SH" "$TAG_PUB" "$W/restored" 2>&1); rc=$?
[ "$rc" != 0 ] && [ ! -e "$W/restored/octocode-db" ] && ok "tampered part -> restore refuses before extracting" || bad "tampered part restored (rc=$rc)"

echo "── disabled / failed pull ──"
reset_store; mk_bj false 1
out=$(run_rel "$REL_SH" cloud-pubrepo); rc=$?
[ "$rc" = 0 ] && [ -z "$(ls "$W/store")" ] && grep -q "disabled" <<<"$out" && ok "enabled=false -> no-op" || bad "disabled config published (rc=$rc)"
mk_bj true 1
out=$(run_rel "$REL_SH" cloud-pubrepo FAKE_PULL_RC=1); rc=$?
[ "$rc" != 0 ] && [ -z "$(ls "$W/store")" ] && ok "image pull failure -> run fails, nothing released" || bad "pull failure not reported (rc=$rc)"

echo "── real config and workflow wiring ──"
BJ_REAL="$REPO_ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json"
if [ -f "$BJ_REAL" ]; then
  jq -e '.per_repo_publish.github_release | .enabled == true and (.surfaces|index("pub")) != null and .part_size_mib >= 1 and .part_size_mib < 2048' "$BJ_REAL" >/dev/null \
    && ok "build.json declares the release channel, parts below 2 GiB" || bad "build.json github_release block"
  jq -e '.per_repo_publish.image_prefix and .per_repo_publish.tag' "$BJ_REAL" >/dev/null && ok "GHCR publish config unchanged alongside" || bad "GHCR publish config missing"
else bad "a_solutions build.json not checked out"; fi
IDX="$REPO_ROOT/.github/workflows/cgc-db-index.yml"; ORCH="$REPO_ROOT/.github/workflows/cgc-db.yml"
python3 - "$IDX" "$ORCH" <<'PY' && ok "index job runs the release step with contents: write; every caller grants it" || bad "workflow wiring"
import sys, yaml
idx = yaml.safe_load(open(sys.argv[1])); orch = yaml.safe_load(open(sys.argv[2]))
job = idx["jobs"]["index"]
assert job["permissions"].get("contents") == "write", job["permissions"]
assert job["permissions"].get("packages") == "write"
steps = [s for s in job["steps"] if "cloud-cgc-db-release.sh" in str(s.get("run", ""))]
assert len(steps) == 1, "release step"
names = [s.get("name", "") for s in job["steps"]]
i = names.index(steps[0]["name"])
assert any("graphrag update" in n for n in names[:i]), "release runs after the index steps"
assert "!cancelled()" in steps[0].get("if", "")
callers = [j for j in orch["jobs"].values() if "cgc-db-index.yml" in str(j.get("uses", ""))]
assert callers and all(j["permissions"].get("contents") == "write" for j in callers), "callers"
PY

echo "── mutations (each must turn a case red) ──"
mutate() { # $1=name $2=python replace old $3=new
  rm -rf "$W/mut"; mkdir -p "$W/mut"; cp "$OPS"/cloud-cgc-db-package.sh "$W/mut/"
  python3 - "$REL_SH" "$W/mut/cloud-cgc-db-release.sh" "$2" "$3" <<'PY'
import sys
s = open(sys.argv[1]).read(); old, new = sys.argv[3], sys.argv[4]
assert old in s, "mutation anchor missing: " + old
open(sys.argv[2], "w").write(s.replace(old, new, 1))
PY
}
mk_bj true 1; mk_db "$W/db" 3
mutate gate 'rel_gate "$_m_pkg" "$_m_local" || return 1' ':'
reset_store; run_rel "$W/mut/cloud-cgc-db-release.sh" cloud-pvtrepo FAKE_CALLER_PRIVATE=false >/dev/null
[ -d "$W/store/$TAG_PVT" ] && ok "mutation (gate removed) -> private index lands on the public caller, caught" || bad "gate mutation not caught"
mutate stale 'gh release delete-asset "$_rpu_tag" "$_rpu_a"' 'true'
reset_store; run_rel "$W/mut/cloud-cgc-db-release.sh" cloud-pubrepo FAKE_DIGEST=sha256:m1 >/dev/null; mk_db "$W/db" 1
out=$(run_rel "$W/mut/cloud-cgc-db-release.sh" cloud-pubrepo FAKE_DIGEST=sha256:m2); rc=$?
[ "$rc" != 0 ] && ok "mutation (stale parts kept) -> asset count check fails the run" || bad "stale mutation not caught"
mk_db "$W/db" 3
mutate remote 'rel_verify_remote "$_m_tag" "$_m_work/out"' ':'
reset_store; out=$(run_rel "$W/mut/cloud-cgc-db-release.sh" cloud-pubrepo FAKE_CORRUPT=octocode-db.tar.$([ "$COMP" = zstd ] && echo zst || echo gz).000); rc=$?
[ "$rc" = 0 ] && ok "mutation (remote verify removed) -> corrupt upload passes, so the check is what catches it" || bad "remote mutation not distinguishable"
mutate unchanged '[ "$(rel_released_digest "$_m_tag")" = "$_m_digest" ]' 'false'
reset_store; run_rel "$W/mut/cloud-cgc-db-release.sh" cloud-pubrepo FAKE_DIGEST=sha256:u1 >/dev/null; : > "$W/store/.uploads"
run_rel "$W/mut/cloud-cgc-db-release.sh" cloud-pubrepo FAKE_DIGEST=sha256:u1 >/dev/null
[ -s "$W/store/.uploads" ] && ok "mutation (digest skip removed) -> re-upload observed, caught" || bad "unchanged mutation not caught"

echo "cgc-db-release: $pass passed, $fail failed"
[ "$fail" = 0 ]
