#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/publish.sh [--dry-run] DIR...

Publishes the builds in DIR (from scripts/build-repo.sh --out DIR) to the
HERMES repository at debian.hermes.radio, in place, on the server:

  1. copies every .changes in DIR, and the files it lists, to the server,
     and checks them there (sha256);
  2. backs up the server's reprepro database, conf, published indices, and
     the pool files of each package being replaced;
  3. includes the uploads (the ones carrying source first), then exports and
     signs the indices once, and checks the signature;
  4. clears the signing passphrase from gpg-agent and regenerates the
     landing page (index.html).

Give the amd64 and the arm64 build directories together, or publish them one
after the other: the source comes with the amd64 (SOURCE_ARCH) build.

Options:
  --dry-run   show what would be uploaded and included; change nothing

Environment:
  REPO_HOST       ssh destination (default: root@debian.hermes.radio)
  REMOTE_BASE     reprepro base dir on the server
                  (default: /root/hermes-repo-state-20260927)
  REMOTE_KEYFILE  signing key passphrase file on the server
                  (default: /root/hermes-repo/key/passphrase)
  CODENAME        distribution (default: trixie)
  SSH, SCP        ssh and scp commands (default: ssh, scp)
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_HOST="${REPO_HOST:-root@debian.hermes.radio}"
REMOTE_BASE="${REMOTE_BASE:-/root/hermes-repo-state-20260927}"
REMOTE_KEYFILE="${REMOTE_KEYFILE:-/root/hermes-repo/key/passphrase}"
CODENAME="${CODENAME:-trixie}"
SSH="${SSH:-ssh}"
SCP="${SCP:-scp}"
DRY_RUN=0

dirs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *) dirs+=("$1"); shift ;;
  esac
done
if [[ "${#dirs[@]}" -eq 0 ]]; then
  usage
  exit 2
fi

command -v dcmd >/dev/null 2>&1 || { echo "ERROR: missing dcmd (devscripts)" >&2; exit 127; }

# --- what to upload -------------------------------------------------------

changes=()
for d in "${dirs[@]}"; do
  shopt -s nullglob
  for c in "$d"/*.changes; do changes+=("$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"); done
  shopt -u nullglob
done
if [[ "${#changes[@]}" -eq 0 ]]; then
  echo "ERROR: no .changes in: ${dirs[*]}" >&2
  exit 1
fi

# Uploads carrying source go first: the binary-only ones need the source's
# orig tarball in the pool, or come with none.
ordered=()
for c in "${changes[@]}"; do
  grep -qE '^Architecture:.*\bsource\b' "$c" && ordered+=("$c")
done
for c in "${changes[@]}"; do
  grep -qE '^Architecture:.*\bsource\b' "$c" || ordered+=("$c")
done

files=()
sources=()
for c in "${ordered[@]}"; do
  while IFS= read -r f; do
    [[ -f "$f" ]] || { echo "ERROR: $(basename "$c") lists $f, which is missing" >&2; exit 1; }
    files+=("$f")
  done < <(dcmd "$c")
  sources+=("$(grep -m1 '^Source:' "$c" | awk '{print $2}')")
done
# one copy of each file name (the server gets them in one directory)
mapfile -t files < <(printf '%s\n' "${files[@]}" | awk -F/ '!seen[$NF]++')
mapfile -t sources < <(printf '%s\n' "${sources[@]}" | sort -u)

echo "==> Publishing to $REPO_HOST:$REMOTE_BASE ($CODENAME)"
for c in "${ordered[@]}"; do
  echo "    $(basename "$c")  [$(grep -m1 '^Architecture:' "$c" | sed 's/^Architecture: //')]"
done
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> Dry run: would upload ${#files[@]} files:"
  printf '    %s\n' "${files[@]##*/}"
  exit 0
fi

# --- upload ---------------------------------------------------------------

stamp="$(date +%Y%m%d-%H%M%S)"
incoming="/root/incoming-$stamp"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for f in "${files[@]}"; do
  (cd "$(dirname "$f")" && sha256sum "$(basename "$f")")
done >"$tmp/SHA256SUMS"

$SSH "$REPO_HOST" "mkdir -p '$incoming'"
$SCP -q "${files[@]}" "$tmp/SHA256SUMS" "$REPO_HOST:$incoming/"
for c in "${ordered[@]}"; do basename "$c"; done >"$tmp/ORDER"
$SCP -q "$tmp/ORDER" "$ROOT_DIR/scripts/gen-index.sh" "$REPO_HOST:$incoming/"
echo "==> Uploaded ${#files[@]} files to $incoming"

# --- include, export, sign (on the server) --------------------------------

# shellcheck disable=SC2087
$SSH "$REPO_HOST" bash -s -- "$incoming" "$REMOTE_BASE" "$REMOTE_KEYFILE" "$CODENAME" "$stamp" "${sources[@]}" <<'REMOTE'
set -Eeuo pipefail
incoming="$1" base="$2" keyfile="$3" codename="$4" stamp="$5"; shift 5
O=(-b "$base" --ignore=unknownfield)

cd "$incoming"
sha256sum -c --quiet SHA256SUMS
echo "==> Checksums ok on the server"

outdir="$(sed -n 's/^outdir[[:space:]]\+//p' "$base/conf/options" 2>/dev/null | head -1)"
outdir="${outdir:-$base}"
mkdir -p "$outdir"
df -h "$outdir" | tail -1 | awk '{print "==> Server disk: "$5" used, "$4" free"}'

backup="/root/repo-backup-$stamp"
mkdir -p "$backup"
cp -a "$base/conf" "$backup/"
[[ -d "$base/db" ]] && cp -a "$base/db" "$backup/"
[[ -d "$outdir/dists" ]] && cp -a "$outdir/dists" "$backup/dists"
for src in "$@"; do
  for d in "$outdir"/pool/main/*/"$src"; do
    [[ -d "$d" ]] && cp -a "$d" "$backup/pool-$src"
  done
done
echo "==> Backup: $backup"

while IFS= read -r ch; do
  out="$(reprepro "${O[@]}" --export=never include "$codename" "$ch" 2>&1)" || { echo "$out" >&2; echo "ERROR: include $ch failed; nothing was exported (backup: $backup)" >&2; exit 1; }
  if grep -q 'There have been errors' <<<"$out"; then
    echo "$out" >&2; echo "ERROR: include $ch failed; nothing was exported (backup: $backup)" >&2; exit 1
  fi
  echo "==> Included $ch"
done <ORDER

key="$(sed -n 's/^SignWith:[[:space:]]*//p' "$base/conf/distributions" | head -1)"
echo x | gpg --batch --no-tty --pinentry-mode loopback --passphrase-file "$keyfile" \
    -u "$key" --clearsign >/dev/null
reprepro "${O[@]}" export "$codename"
gpgconf --reload gpg-agent
gpg --verify "$outdir/dists/$codename/InRelease" 2>&1 | grep -q 'Good signature' \
  || { echo "ERROR: $outdir/dists/$codename/InRelease is not correctly signed" >&2; exit 1; }
echo "==> Exported and signed $codename"

for src in "$@"; do
  reprepro "${O[@]}" list "$codename" | grep -E "(: $src |\| *$src )" || true
done
REMOTE

# landing page, from the server's database
outdir="$($SSH "$REPO_HOST" "sed -n 's/^outdir[[:space:]]\+//p' '$REMOTE_BASE/conf/options' | head -1")"
$SSH "$REPO_HOST" bash "$incoming/gen-index.sh" --repo-dir "$REMOTE_BASE" \
  --out "$(dirname "${outdir:-$REMOTE_BASE/x}")/index.html" >/dev/null
echo "==> Landing page updated"
echo "Done. Check from a station: sudo apt update && apt policy ${sources[*]}"
