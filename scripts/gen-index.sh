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
  REPO_URL      URL shown on the page (default: http://debian.hermes.radio/)
  KEY_FILE      Key file name (default: hermes.key)
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

REPO_URL="${REPO_URL:-https://debian.hermes.radio/hermes/}"
KEY_FILE="${KEY_FILE:-hermes.key}"
APT_URL="${APT_URL:-http://debian.hermes.radio/hermes}"

mapfile -t CODENAMES < <(grep -E '^Codename:' "$REPO_DIR/conf/distributions" | sed -E 's/^Codename:[[:space:]]*//')
COMPONENTS="$(grep -m1 -E '^Components:' "$REPO_DIR/conf/distributions" | sed -E 's/^Components:[[:space:]]*//')"
SUITE="$(grep -m1 -E '^Suite:' "$REPO_DIR/conf/distributions" | sed -E 's/^Suite:[[:space:]]*//')"
SUITE="${SUITE:-${CODENAMES[0]:-trixie}}"
COMPONENTS="${COMPONENTS:-main}"

LIST_FORMAT='${$codename}|${$component}|${$architecture}: ${package} ${version}\n'

pkg_lines=""
for c in "${CODENAMES[@]}"; do
  out="$(reprepro -b "$REPO_DIR" --ignore=unknownfield --ignore=undefinedtarget --list-format "$LIST_FORMAT" list "$c" 2>/dev/null || true)"
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
    Instructions (Debian 13 Trixie):<br /> <br />
    # Install the repository certificate<br />
    wget --no-check-certificate -qO- ${REPO_URL%/}/${KEY_FILE} | gpg --dearmor -o - > /etc/apt/trusted.gpg.d/hermes.gpg<br />
    <br />
    # For ARM64 (Debian/Raspberry Pi OS running on arm64 hardware, such as Raspberry Pi, present in the sBitx radio)<br />
    echo 'deb [arch=arm64] ${APT_URL} ${SUITE} ${COMPONENTS}' &gt;&gt; /etc/apt/sources.list.d/hermes.list<br />
    # For ARM64 (Debian running on x86_64 hardware, such as a laptop or desktop computer)<br />
    echo 'deb [arch=amd64] ${APT_URL} ${SUITE} ${COMPONENTS}' &gt;&gt; /etc/apt/sources.list.d/hermes.list<br />
    <br />
    apt-get update<br />
    <br />
    <hr />
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
