#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-repo.sh [repo-name...]

Clones/updates each URL in list.txt (default branch), builds with:
  debuild -uc -us .
and includes the resulting *.changes into a reprepro repo.

Environment:
  LIST_FILE      Path to list file (default: ./list.txt)
  REPO_DIR       reprepro base dir (default: ./repository)
  CODENAME       reprepro codename to include into (default: trixie)
  WORK_DIR       Workspace (default: ./work)
  FORCE_ORIG     1 to regenerate *.orig.tar.gz (default: 0)
  DEBUILD_CMD_OPTS        Options for debuild itself (default: "--no-lintian")
  DPKG_BUILDPACKAGE_OPTS  Options passed to dpkg-buildpackage (e.g. "-S -d") (default: empty)
  DEBUILD_OPTS            Alias for DPKG_BUILDPACKAGE_OPTS (backwards compat)

Examples:
  scripts/build-repo.sh                 # build all from list.txt
  scripts/build-repo.sh csdr vvenc      # build only these repos
  DPKG_BUILDPACKAGE_OPTS="-S -d" scripts/build-repo.sh csdr
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST_FILE="${LIST_FILE:-$ROOT_DIR/list.txt}"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repository}"
CODENAME="${CODENAME:-trixie}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
FORCE_ORIG="${FORCE_ORIG:-0}"
DEBUILD_CMD_OPTS="${DEBUILD_CMD_OPTS:---no-lintian}"
DPKG_BUILDPACKAGE_OPTS="${DPKG_BUILDPACKAGE_OPTS:-${DEBUILD_OPTS:-}}"

[[ "$LIST_FILE" != /* ]] && LIST_FILE="$ROOT_DIR/$LIST_FILE"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT_DIR/$REPO_DIR"
[[ "$WORK_DIR" != /* ]] && WORK_DIR="$ROOT_DIR/$WORK_DIR"

CURRENT_NAME=""
CURRENT_URL=""
CURRENT_STEP=""
on_err() {
  local ec=$?
  echo >&2
  echo "ERROR: scripts/build-repo.sh failed (exit=$ec)" >&2
  [[ -n "${CURRENT_NAME:-}" ]] && echo "  package: $CURRENT_NAME" >&2
  [[ -n "${CURRENT_URL:-}" ]] && echo "  url: $CURRENT_URL" >&2
  [[ -n "${CURRENT_STEP:-}" ]] && echo "  step: $CURRENT_STEP" >&2
  echo "  command: ${BASH_COMMAND}" >&2
  echo >&2
  exit "$ec"
}
trap on_err ERR

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 127; }
}

need_cmd git
need_cmd debuild
need_cmd dpkg-parsechangelog
need_cmd reprepro
need_cmd tar

if [[ ! -f "$LIST_FILE" ]]; then
  echo "ERROR: list file not found: $LIST_FILE" >&2
  exit 1
fi
if [[ ! -f "$REPO_DIR/conf/distributions" ]]; then
  echo "ERROR: reprepro not initialized; missing: $REPO_DIR/conf/distributions" >&2
  echo "Run: scripts/repo-init.sh ..." >&2
  exit 1
fi

mkdir -p "$WORK_DIR"

DEBUILD_CMD_OPTS_ARR=()
if [[ -n "$DEBUILD_CMD_OPTS" ]]; then
  # shellcheck disable=SC2206
  DEBUILD_CMD_OPTS_ARR=($DEBUILD_CMD_OPTS)
fi

DPKG_BUILDPACKAGE_OPTS_ARR=()
if [[ -n "$DPKG_BUILDPACKAGE_OPTS" ]]; then
  # shellcheck disable=SC2206
  DPKG_BUILDPACKAGE_OPTS_ARR=($DPKG_BUILDPACKAGE_OPTS)
fi

want_repo() {
  local name="$1"
  shift || true
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  local x
  for x in "$@"; do
    [[ "${x,,}" == "${name,,}" ]] && return 0
  done
  return 1
}

repo_main_component() {
  local c
  c="$(grep -m1 -E '^Components:' "$REPO_DIR/conf/distributions" | sed -E 's/^Components:[[:space:]]*//')"
  set -- $c
  printf '%s\n' "${1:-main}"
}

dpkg_opts_build_source() {
  local o
  for o in "${DPKG_BUILDPACKAGE_OPTS_ARR[@]}"; do
    case "$o" in
      -b|-B|-A|--build=binary|--build=any|--build=all) return 1 ;;
    esac
  done
  return 0
}

dpkg_opts_has_sa_sd_si() {
  local o
  for o in "${DPKG_BUILDPACKAGE_OPTS_ARR[@]}"; do
    case "$o" in
      -sa|-sd|-si) return 0 ;;
    esac
  done
  return 1
}

default_branch() {
  local src_dir="$1"
  local ref
  ref="$(git -C "$src_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  ref="${ref#origin/}"
  [[ -n "$ref" ]] && { printf '%s\n' "$ref"; return 0; }
  printf '%s\n' main
}

needs_export_build() {
  local src_dir="$1"
  local fmt_file="$src_dir/debian/source/format"
  [[ -f "$fmt_file" ]] || return 0
  local fmt
  fmt="$(<"$fmt_file")"
  [[ "$fmt" == "3.0 (quilt)" || "$fmt" == "3.0 (native)" ]] && return 1
  return 0
}

export_worktree() {
  local src_dir="$1"
  local out_dir="$2"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  git -C "$src_dir" archive --format=tar HEAD | tar -x -C "$out_dir"
}

patch_drop_with_quilt() {
  local src_dir="$1"
  local rules="$src_dir/debian/rules"
  [[ -f "$rules" ]] || return 0
  grep -q "with quilt" "$rules" || return 0
  echo "Patching debian/rules: dropping '--with quilt' (not available on this debhelper)" >&2
  sed -i -E 's/[[:space:]]+--with[[:space:]]+quilt//g; s/[[:space:]]+--with=quilt//g' "$rules"
}

ensure_orig_tarball() {
  local src_dir="$1"
  local out_dir="$2"

  local format=""
  if [[ -f "$src_dir/debian/source/format" ]]; then
    format="$(<"$src_dir/debian/source/format")"
  fi
  if [[ "$format" == "3.0 (native)" ]]; then
    return 0
  fi

  local source version upstream
  source="$(cd "$src_dir" && dpkg-parsechangelog -S Source)"
  version="$(cd "$src_dir" && dpkg-parsechangelog -S Version)"

  # Native packages have no Debian revision (no last "-<rev>").
  if [[ "$version" != *-* ]]; then
    return 0
  fi

  upstream="${version#*:}"
  upstream="${upstream%-*}"

  local orig="$out_dir/${source}_${upstream}.orig.tar.gz"
  if [[ "$FORCE_ORIG" != "1" && -f "$orig" ]]; then
    return 0
  fi

  echo "Generating orig tarball: $orig" >&2
  (
    cd "$src_dir"
    tar -czf "$orig" \
      --exclude='./debian' \
      --exclude-vcs \
      --transform "s,^\\./,${source}-${upstream}/," \
      .
  )
}

include_changes() {
  local src_dir="$1"
  local out_dir="$2"
  local stamp_file="${3:-}"

  local source version
  source="$(cd "$src_dir" && dpkg-parsechangelog -S Source)"
  version="$(cd "$src_dir" && dpkg-parsechangelog -S Version)"

  local changes=()
  if [[ -n "$stamp_file" && -f "$stamp_file" ]]; then
    while IFS= read -r f; do changes+=("$f"); done < <(
      find "$out_dir" -maxdepth 1 -type f -name "${source}_${version}_*.changes" -newer "$stamp_file" -print
    )
  else
    shopt -s nullglob
    changes=("$out_dir/${source}_${version}"_*.changes)
    shopt -u nullglob
  fi

  if [[ "${#changes[@]}" -eq 0 ]]; then
    echo "ERROR: no .changes found for ${source}_${version} in $out_dir" >&2
    exit 1
  fi

  local ch
  for ch in "${changes[@]}"; do
    reprepro -b "$REPO_DIR" --ignore=wrongdistribution include "$CODENAME" "$ch"
  done
}

while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="$raw"
  line="${line%%#*}"
  line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^[0-9]+\\.[[:space:]]*//')"
  [[ -z "$line" ]] && continue

  url="$line"
  name="$(basename "$url")"
  name="${name%.git}"

  if ! want_repo "$name" "$@"; then
    continue
  fi

  CURRENT_NAME="$name"
  CURRENT_URL="$url"
  CURRENT_STEP="clone/update"
  echo "==> [$name] $url" >&2

  pkg_dir="$WORK_DIR/$name"
  src_dir="$pkg_dir/src"
  mkdir -p "$pkg_dir"

  if [[ ! -d "$src_dir/.git" ]]; then
    git clone "$url" "$src_dir"
  else
    if ! git -C "$src_dir" diff --quiet || ! git -C "$src_dir" diff --cached --quiet; then
      echo "ERROR: working tree not clean: $src_dir" >&2
      exit 1
    fi
    git -C "$src_dir" fetch --prune origin
  fi

  branch="$(default_branch "$src_dir")"
  git -C "$src_dir" checkout "$branch"
  git -C "$src_dir" pull --ff-only origin "$branch"

  source_pkg="$(cd "$src_dir" && dpkg-parsechangelog -S Source)"
  version_pkg="$(cd "$src_dir" && dpkg-parsechangelog -S Version)"
  upstream_pkg="${version_pkg#*:}"
  upstream_pkg="${upstream_pkg%-*}"
  orig_name="${source_pkg}_${upstream_pkg}.orig.tar.gz"

  build_src_dir="$src_dir"
  need_quilt_patch=0
  if ! dh --list | grep -qx quilt; then
    [[ -f "$src_dir/debian/rules" ]] && grep -q "with quilt" "$src_dir/debian/rules" && need_quilt_patch=1
  fi

  if needs_export_build "$src_dir" || [[ "$need_quilt_patch" -eq 1 ]]; then
    build_src_dir="$pkg_dir/${source_pkg}-${upstream_pkg}"
    export_worktree "$src_dir" "$build_src_dir"
  fi

  [[ "$need_quilt_patch" -eq 1 ]] && patch_drop_with_quilt "$build_src_dir"

  CURRENT_STEP="orig tarball"
  ensure_orig_tarball "$build_src_dir" "$pkg_dir"

  build_stamp="$(mktemp -p "$pkg_dir" .build-stamp.XXXXXX)"
  CURRENT_STEP="debuild"
  (
    cd "$build_src_dir"
    extra_dpkg_opts=()
    if dpkg_opts_build_source && ! dpkg_opts_has_sa_sd_si; then
      main_comp="$(repo_main_component)"
      if [[ ! -f "$REPO_DIR/pool/$main_comp/${source_pkg:0:1}/$source_pkg/$orig_name" ]]; then
        extra_dpkg_opts+=(-sa)
      fi
    fi

    debuild "${DEBUILD_CMD_OPTS_ARR[@]}" -uc -us "${DPKG_BUILDPACKAGE_OPTS_ARR[@]}" "${extra_dpkg_opts[@]}" .
  )

  CURRENT_STEP="reprepro include"
  include_changes "$build_src_dir" "$pkg_dir" "$build_stamp"
  rm -f "$build_stamp"
  echo "==> [$name] OK" >&2
done <"$LIST_FILE"

CURRENT_STEP="reprepro export"
reprepro -b "$REPO_DIR" export "$CODENAME"
CURRENT_STEP="gen-index"
"$ROOT_DIR/scripts/gen-index.sh" --repo-dir "$REPO_DIR"

echo "Done. Repo: $REPO_DIR (codename: $CODENAME)"
