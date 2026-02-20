#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/upload-repo.sh --dest user@host:/var/www/html [options]

Uploads:
  - ./repository/  -> <dest>/<repo-subdir>/
  - ./index.html   -> <dest>/index.html

Options:
  --dest DEST          Required. rsync destination root (e.g. user@host:/var/www/html)
  --repo-subdir NAME   Remote subdir for the repo (default: hermes)
  --dry-run            Pass --dry-run to rsync
  --delete             Pass --delete to rsync
  -h, --help           Show help
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repository}"
INDEX_FILE="${INDEX_FILE:-$ROOT_DIR/index.html}"

command -v rsync >/dev/null 2>&1 || { echo "ERROR: missing required command: rsync" >&2; exit 127; }

DEST=""
REPO_SUBDIR="hermes"
DRY_RUN=0
DELETE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --repo-subdir) REPO_SUBDIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --delete) DELETE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$DEST" ]]; then
  echo "ERROR: --dest is required" >&2
  usage
  exit 2
fi
if [[ ! -d "$REPO_DIR" ]]; then
  echo "ERROR: repo dir not found: $REPO_DIR" >&2
  exit 1
fi
if [[ ! -f "$INDEX_FILE" ]]; then
  echo "ERROR: index.html not found: $INDEX_FILE" >&2
  exit 1
fi

RSYNC_OPTS=(-avz)
[[ "$DRY_RUN" -eq 1 ]] && RSYNC_OPTS+=(--dry-run)
[[ "$DELETE" -eq 1 ]] && RSYNC_OPTS+=(--delete)

rsync "${RSYNC_OPTS[@]}" "$REPO_DIR"/ "$DEST/$REPO_SUBDIR"/
rsync "${RSYNC_OPTS[@]}" "$INDEX_FILE" "$DEST/index.html"

echo "Uploaded repo to: $DEST/$REPO_SUBDIR/"
