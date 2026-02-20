#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/gen-index.sh [options]

Generates ./index.html similar to http://packages.hermes.radio/ using reprepro list output.

Options:
  --repo-dir DIR     reprepro base dir (default: ./repository)
  --out FILE         output file (default: ./index.html)
  -h, --help         show help

Environment:
  REPO_URL      URL shown on the page (default: http://packages.hermes.radio/hermes/)
  KEY_FILE      Key file name (default: rafael.key)
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repository}"
OUT_FILE="$ROOT_DIR/index.html"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -f "$REPO_DIR/conf/distributions" ]]; then
  echo "ERROR: missing $REPO_DIR/conf/distributions" >&2
  exit 1
fi

REPO_URL="${REPO_URL:-http://packages.hermes.radio/hermes/}"
KEY_FILE="${KEY_FILE:-rafael.key}"

mapfile -t CODENAMES < <(grep -E '^Codename:' "$REPO_DIR/conf/distributions" | sed -E 's/^Codename:[[:space:]]*//')
COMPONENTS="$(grep -m1 -E '^Components:' "$REPO_DIR/conf/distributions" | sed -E 's/^Components:[[:space:]]*//')"
SUITE="$(grep -m1 -E '^Suite:' "$REPO_DIR/conf/distributions" | sed -E 's/^Suite:[[:space:]]*//')"
SUITE="${SUITE:-${CODENAMES[0]:-trixie}}"
COMPONENTS="${COMPONENTS:-main}"

LIST_FORMAT='${$codename}|${$component}|${$architecture}: ${package} ${version}\n'

pkg_lines=""
for c in "${CODENAMES[@]}"; do
  out="$(reprepro -b "$REPO_DIR" --list-format "$LIST_FORMAT" list "$c" 2>/dev/null || true)"
  [[ -z "$out" ]] && continue
  pkg_lines+=$'\n'"$out"
done

pkg_lines="$(printf '%s\n' "$pkg_lines" | sed '/^$/d' | grep -v '|source:' || true)"
pkg_lines="$(printf '%s\n' "$pkg_lines" | sort -u)"

{
  cat <<EOF
<html>
  <head>
  <title>Rhizomatica's HERMES repository</title>
  </head>
  <body>
    HERMES DEBIAN PACKAGE REPOSITORY: <a href="${REPO_URL}">${REPO_URL}</a><br /> <br/>
    Instructions (Debian trixie):<br /> <br />
    wget ${REPO_URL%/}/${KEY_FILE}<br />
    apt-key add ${KEY_FILE}<br />
    echo deb ${REPO_URL} ${SUITE} ${COMPONENTS} &gt;&gt; /etc/apt/sources.list<br />
    apt-get update<br />
    <br />
    <br />
    Available packages:<br />
EOF
  if [[ -n "$pkg_lines" ]]; then
    # Use '|' delimiter so we don't have to escape '/' in "<br />".
    printf '%s\n' "$pkg_lines" | sed 's|^|<br />|'
  fi
  cat <<'EOF'

  </body>
  </html>
EOF
} >"$OUT_FILE"

echo "Wrote: $OUT_FILE"
