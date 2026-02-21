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
  FORCE_ORIG     1 to force regenerating *.orig.tar.gz from source (default: 0)
  FORCE_REBUILD  1 to rebuild even if same version already in repo (default: 0)
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
FORCE_REBUILD="${FORCE_REBUILD:-0}"
HOST_ARCH="${HOST_ARCH:-$(dpkg --print-architecture)}"
DEBUILD_CMD_OPTS="${DEBUILD_CMD_OPTS:---no-lintian}"
DPKG_BUILDPACKAGE_OPTS="${DPKG_BUILDPACKAGE_OPTS:-${DEBUILD_OPTS:-}}"
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-$ROOT_DIR/key/passphrase}"

[[ "$LIST_FILE" != /* ]] && LIST_FILE="$ROOT_DIR/$LIST_FILE"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT_DIR/$REPO_DIR"
[[ "$WORK_DIR" != /* ]] && WORK_DIR="$ROOT_DIR/$WORK_DIR"
[[ "$GPG_PASSPHRASE_FILE" != /* ]] && GPG_PASSPHRASE_FILE="$ROOT_DIR/$GPG_PASSPHRASE_FILE"

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

gpg_setup_tty() {
  if [[ -t 0 ]]; then
    export GPG_TTY
    GPG_TTY="$(tty 2>/dev/null || true)"
    [[ -n "$GPG_TTY" ]] && gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
  fi
}

repo_sign_with() {
  local v
  v="$(grep -m1 -E '^SignWith:' "$REPO_DIR/conf/distributions" 2>/dev/null | sed -E 's/^SignWith:[[:space:]]*//')"
  printf '%s\n' "$v"
}

maybe_preset_signing_passphrase() {
  # Best-effort: avoid gpgme pinentry timeouts by priming gpg-agent's cache
  # using loopback mode + a passphrase file.
  gpg_setup_tty

  [[ -f "$GPG_PASSPHRASE_FILE" ]] || return 0
  [[ -f "$REPO_DIR/conf/distributions" ]] || return 0
  command -v gpg >/dev/null 2>&1 || return 0

  local sign_with
  sign_with="$(repo_sign_with)"
  [[ -n "$sign_with" ]] || return 0
  case "$sign_with" in
    yes|default|!*) return 0 ;;
  esac

  # This will cache the passphrase in gpg-agent (no pinentry).
  if ! printf 'cache\n' | gpg --batch --yes \
    --pinentry-mode loopback \
    --passphrase-file "$GPG_PASSPHRASE_FILE" \
    --local-user "$sign_with" \
    --clearsign >/dev/null 2>&1; then
    echo "WARN: failed to prime gpg-agent cache; signing may require interactive pinentry" >&2
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 127; }
}

need_cmd git
need_cmd debuild
need_cmd dpkg
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

pool_prefix() {
  local src="$1"
  if [[ "$src" == lib* && "${#src}" -ge 4 ]]; then
    printf '%s\n' "${src:0:4}"
  else
    printf '%s\n' "${src:0:1}"
  fi
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

dpkg_opts_source_only() {
  local o
  for o in "${DPKG_BUILDPACKAGE_OPTS_ARR[@]}"; do
    case "$o" in
      -S|--build=source) return 0 ;;
    esac
  done
  return 1
}

repo_has_binaries_for_sourcever_arch() {
  local src="$1"
  local ver="$2"
  local arch="$3"
  local formula
  formula="\$Source (== $src), \$SourceVersion (== $ver)"
  reprepro -b "$REPO_DIR" -T deb -A "$arch" --list-max 1 listfilter "$CODENAME" "$formula" 2>/dev/null | grep -q .
}

repo_has_sourcever() {
  local src="$1"
  local ver="$2"
  reprepro -b "$REPO_DIR" -T dsc --list-max 1 listfilter "$CODENAME" "Package (== $src), Version (== $ver)" 2>/dev/null | grep -q .
}

changes_arches() {
  local ch="$1"
  grep -m1 '^Architecture:' "$ch" 2>/dev/null | sed -E 's/^Architecture:[[:space:]]*//' || true
}

replace_existing_binaries_for() {
  local src="$1"
  local ver="$2"
  local arch_list="$3"
  local formula="\$Source (== $src), \$SourceVersion (== $ver)"

  local a
  for a in $arch_list; do
    [[ "$a" == "source" ]] && continue
    echo "==> [$CURRENT_NAME] removing existing $a binaries for $src $ver" >&2
    reprepro -b "$REPO_DIR" --export=silent-never -T deb -A "$a" removefilter "$CODENAME" "$formula" >/dev/null 2>&1 || true
    reprepro -b "$REPO_DIR" --export=silent-never -T ddeb -A "$a" removefilter "$CODENAME" "$formula" >/dev/null 2>&1 || true
  done

  # Drop old pool files/checksum registrations that are no longer referenced.
  reprepro -b "$REPO_DIR" --export=silent-never deleteunreferenced >/dev/null 2>&1 || true
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
  local preferred_dir="$2"

  local out_dir="$preferred_dir"
  if [[ -e "$out_dir" ]]; then
    if ! rm -rf "$out_dir" 2>/dev/null; then
      # Likely left behind by a previous run as root. Don't fail the whole build;
      # create a new export dir for this run.
      local parent base
      parent="$(dirname "$preferred_dir")"
      base="$(basename "$preferred_dir")"
      out_dir="$(mktemp -d -p "$parent" "${base}.XXXXXX")"
    fi
  fi
  mkdir -p "$out_dir"

  git -C "$src_dir" archive --format=tar HEAD | tar -x -C "$out_dir"
  printf '%s\n' "$out_dir"
}

needs_export_due_to_untracked() {
  local src_dir="$1"
  local untracked
  untracked="$(git -C "$src_dir" ls-files --others --exclude-standard || true)"
  [[ -z "$untracked" ]] && return 1
  # If there are non-debian untracked files, dpkg-source (3.0 quilt) may fail.
  if printf '%s\n' "$untracked" | grep -qvE '^(debian/|\\.pc/)'; then
    return 0
  fi
  return 1
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
  local main_comp prefix repo_orig
  main_comp="$(repo_main_component)"
  prefix="$(pool_prefix "$source")"
  repo_orig="$REPO_DIR/pool/$main_comp/$prefix/$source/${source}_${upstream}.orig.tar.gz"

  # If the repo already has an orig tarball for this upstream version, reuse it
  # to avoid checksum conflicts across Debian revisions.
  if [[ "$FORCE_ORIG" != "1" && -f "$repo_orig" ]]; then
    cp -f "$repo_orig" "$orig"
    return 0
  fi

  echo "Generating orig tarball: $orig" >&2
  (
    cd "$src_dir"
    tar -cf - \
      --exclude='./debian' \
      --exclude-vcs \
      --transform "s,^\\./,${source}-${upstream}/," \
      . | gzip -n >"$orig"
  )
}

include_changes() {
  local src_dir="$1"
  local out_dir="$2"
  local stamp_file="${3:-}"

  local source version filever
  source="$(cd "$src_dir" && dpkg-parsechangelog -S Source)"
  version="$(cd "$src_dir" && dpkg-parsechangelog -S Version)"
  filever="${version#*:}"  # strip epoch for filenames

  local changes=()
  if [[ -n "$stamp_file" && -f "$stamp_file" ]]; then
    while IFS= read -r f; do changes+=("$f"); done < <(
      find "$out_dir" -maxdepth 1 -type f -name "${source}_${filever}_*.changes" -newer "$stamp_file" -print
    )
  else
    shopt -s nullglob
    changes=("$out_dir/${source}_${filever}"_*.changes)
    shopt -u nullglob
  fi

  if [[ "${#changes[@]}" -eq 0 ]]; then
    echo "ERROR: no .changes found for ${source}_${filever} in $out_dir" >&2
    exit 1
  fi

  local ch
  for ch in "${changes[@]}"; do
    local out ec arch_list
    if out="$(reprepro -b "$REPO_DIR" --export=silent-never --ignore=wrongdistribution include "$CODENAME" "$ch" 2>&1)"; then
      ec=0
    else
      ec=$?
    fi
    if [[ "$ec" -eq 0 ]] && grep -q 'There have been errors' <<<"$out"; then
      ec=1
    fi
    [[ "$ec" -eq 0 ]] && continue
    if [[ "$FORCE_REBUILD" == "1" ]] && grep -q "already registered with different checksums" <<<"$out"; then
      echo "WARN: checksum mismatch while including (forced rebuild). Replacing existing binaries and retrying..." >&2
      arch_list="$(changes_arches "$ch")"
      [[ -n "$arch_list" ]] || arch_list="$HOST_ARCH all"
      replace_existing_binaries_for "$source" "$version" "$arch_list"

      if out="$(reprepro -b "$REPO_DIR" --export=silent-never --ignore=wrongdistribution include "$CODENAME" "$ch" 2>&1)"; then
        ec=0
      else
        ec=$?
      fi
      if [[ "$ec" -eq 0 ]] && grep -q 'There have been errors' <<<"$out"; then
        ec=1
      fi
      [[ "$ec" -eq 0 ]] && continue
    fi

    echo "$out" >&2
    return "$ec"
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
  if [[ -e "$pkg_dir" && ! -w "$pkg_dir" ]]; then
    echo "WARN: $pkg_dir is not writable (likely created by root). Using a new work dir for this run." >&2
    pkg_dir="$(mktemp -d -p "$WORK_DIR" "${name}.XXXXXX")"
  fi
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
  CURRENT_STEP="checkout"
  if git -C "$src_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$src_dir" checkout "$branch" >/dev/null
  else
    git -C "$src_dir" checkout -b "$branch" "origin/$branch" >/dev/null
  fi

  # Always sync to the remote branch head (handles force-push/diverged branches).
  CURRENT_STEP="sync"
  if ! git -C "$src_dir" reset --hard "origin/$branch" >/dev/null; then
    echo "ERROR: failed to reset to origin/$branch (does it exist?)" >&2
    exit 1
  fi

  source_pkg="$(cd "$src_dir" && dpkg-parsechangelog -S Source)"
  version_pkg="$(cd "$src_dir" && dpkg-parsechangelog -S Version)"

  if [[ "$FORCE_REBUILD" != "1" ]]; then
    if dpkg_opts_source_only; then
      if repo_has_sourcever "$source_pkg" "$version_pkg"; then
        echo "==> [$name] already in repo (source $source_pkg $version_pkg), skipping (set FORCE_REBUILD=1 to rebuild)" >&2
        continue
      fi
    else
      if repo_has_binaries_for_sourcever_arch "$source_pkg" "$version_pkg" "$HOST_ARCH"; then
        echo "==> [$name] already in repo ($HOST_ARCH $source_pkg $version_pkg), skipping (set FORCE_REBUILD=1 to rebuild)" >&2
        continue
      fi
    fi
  fi

  upstream_pkg="${version_pkg#*:}"
  upstream_pkg="${upstream_pkg%-*}"
  orig_name="${source_pkg}_${upstream_pkg}.orig.tar.gz"

  build_src_dir="$src_dir"
  need_quilt_patch=0
  if ! dh --list | grep -qx quilt; then
    [[ -f "$src_dir/debian/rules" ]] && grep -q "with quilt" "$src_dir/debian/rules" && need_quilt_patch=1
  fi

  if needs_export_build "$src_dir" || [[ "$need_quilt_patch" -eq 1 ]] || needs_export_due_to_untracked "$src_dir"; then
    build_src_dir="$pkg_dir/${source_pkg}-${upstream_pkg}"
    build_src_dir="$(export_worktree "$src_dir" "$build_src_dir")"
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
      prefix="$(pool_prefix "$source_pkg")"
      if [[ ! -f "$REPO_DIR/pool/$main_comp/$prefix/$source_pkg/$orig_name" ]]; then
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
maybe_preset_signing_passphrase || true
reprepro -b "$REPO_DIR" export "$CODENAME"
CURRENT_STEP="gen-index"
"$ROOT_DIR/scripts/gen-index.sh" --repo-dir "$REPO_DIR"

echo "Done. Repo: $REPO_DIR (codename: $CODENAME)"
