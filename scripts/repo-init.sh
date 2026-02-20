#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/repo-init.sh [options]

Creates a reprepro repository under ./repository for Debian trixie.

Options:
  --repo-dir DIR          Repo directory (default: ./repository)
  --codename NAME         Distribution codename (default: trixie)
  --suite NAME            Suite name (default: trixie)
  --components LIST       Components (default: main)
  --architectures LIST    Architectures (default: "amd64 arm64 source")
  --sign-with KEYID       GPG key id/fingerprint for SignWith:
  --unsigned              Do not set SignWith: (unsigned repo)
  -h, --help              Show this help

Examples:
  scripts/repo-init.sh --unsigned
  scripts/repo-init.sh --sign-with 'ABCD1234...'
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repository}"
CODENAME="${CODENAME:-trixie}"
SUITE="${SUITE:-trixie}"
COMPONENTS="${COMPONENTS:-main}"
ARCHS="${ARCHS:-amd64 arm64 source}"
SIGN_WITH="${SIGN_WITH:-}"
UNSIGNED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --codename) CODENAME="$2"; shift 2 ;;
    --suite) SUITE="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    --architectures) ARCHS="$2"; shift 2 ;;
    --sign-with) SIGN_WITH="$2"; shift 2 ;;
    --unsigned) UNSIGNED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

mkdir -p "$REPO_DIR/conf" "$REPO_DIR/db" "$REPO_DIR/dists" "$REPO_DIR/pool" "$REPO_DIR/lists" "$REPO_DIR/logs"

if [[ "$UNSIGNED" -eq 0 && -z "$SIGN_WITH" ]]; then
  echo "ERROR: provide --sign-with KEYID (you create the key) or use --unsigned" >&2
  exit 1
fi

if [[ "$UNSIGNED" -eq 0 && -n "$SIGN_WITH" && -x "$(command -v gpg)" ]]; then
  if ! gpg --batch --list-secret-keys "$SIGN_WITH" >/dev/null 2>&1; then
    echo "WARN: gpg secret key '$SIGN_WITH' not found (reprepro signing will fail until it's available)" >&2
  fi
fi

{
  echo "Codename: $CODENAME"
  echo "Suite: $SUITE"
  echo "Components: $COMPONENTS"
  echo "Architectures: $ARCHS"
  echo "Description: HERMES extra packages"
  echo "Origin: HERMES"
  echo "Label: HERMES"
  echo "AlsoAcceptFor: unstable stable UNRELEASED"
  echo "DDebComponents: $COMPONENTS"
  if [[ "$UNSIGNED" -eq 0 ]]; then
    echo "SignWith: $SIGN_WITH"
  fi
} >"$REPO_DIR/conf/distributions"

echo "Initialized reprepro config at: $REPO_DIR/conf/distributions"

