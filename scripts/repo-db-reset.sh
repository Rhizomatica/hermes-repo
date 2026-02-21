#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/repo-db-reset.sh [options]

Options:
  --repo-dir DIR         Repo base dir (default: ./repository)
  --erase-db             Move repository/db to repository/db.deleted.TIMESTAMP (safe erase)
  --erase-references     Move repository/db/references.db to references.db.deleted.TIMESTAMP
  --no-backup            Do not keep backups when erasing (dangerous)
  --rereference          Run 'reprepro rereference' after changes
  --clearvanished        Run 'reprepro clearvanished' after changes
  --detect               Run '_detect' to rebuild files db from pool
  -h, --help             Show this help

Examples:
  # Erase the whole db (backup kept) and rereference
  scripts/repo-db-reset.sh --erase-db --rereference

  # Remove just references.db (no backup)
  scripts/repo-db-reset.sh --erase-references --no-backup
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repository}"

NO_BACKUP=0
DO_ERASE_DB=0
DO_ERASE_REFS=0
DO_REREF=0
DO_CLEARV=0
DO_DETECT=0

if [[ "$#" -eq 0 ]]; then
  usage
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --erase-db) DO_ERASE_DB=1; shift ;;
    --erase-references) DO_ERASE_REFS=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --rereference) DO_REREF=1; shift ;;
    --clearvanished) DO_CLEARV=1; shift ;;
    --detect) DO_DETECT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -d "$REPO_DIR" ]]; then
  echo "ERROR: repository dir not found: $REPO_DIR" >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

# Erase full db directory (safe: move to backup unless --no-backup)
if [[ "$DO_ERASE_DB" -eq 1 ]]; then
  if [[ -e "$REPO_DIR/db" ]]; then
    if [[ "$NO_BACKUP" -ne 1 ]]; then
      dest="$REPO_DIR/db.deleted.$timestamp"
      echo "Backing up $REPO_DIR/db -> $dest"
      mv "$REPO_DIR/db" "$dest"
    else
      echo "Removing $REPO_DIR/db (no backup)"
      rm -rf "$REPO_DIR/db"
    fi
    mkdir -p "$REPO_DIR/db"
    echo "Erased DB directory at $REPO_DIR/db"
  else
    echo "No db dir at $REPO_DIR/db to erase"
  fi
fi

# Erase only references.db
if [[ "$DO_ERASE_REFS" -eq 1 ]]; then
  ref="$REPO_DIR/db/references.db"
  if [[ -e "$ref" ]]; then
    if [[ "$NO_BACKUP" -ne 1 ]]; then
      dest="$REPO_DIR/db/references.db.deleted.$timestamp"
      echo "Backing up references.db -> $dest"
      mv "$ref" "$dest"
    else
      echo "Removing $ref (no backup)"
      rm -f "$ref"
    fi
    echo "references.db handled"
  else
    echo "No references.db at $ref"
  fi
fi

# Helper to run reprepro with safe ignore flags
run_reprepro() {
  local cmd=(reprepro -b "$REPO_DIR" --ignore=unknownfield --ignore=undefinedtarget "$@")
  echo "Running: ${cmd[*]}"
  "${cmd[@]}"
}

if [[ "$DO_CLEARV" -eq 1 ]]; then
  run_reprepro clearvanished || true
fi

if [[ "$DO_REREF" -eq 1 ]]; then
  run_reprepro rereference || true
fi

if [[ "$DO_DETECT" -eq 1 ]]; then
  echo "Running _detect to rebuild file DB from pool (may take time)"
  (cd "$REPO_DIR" && find pool -type f -print | reprepro -b . _detect)
fi

echo "Done."
