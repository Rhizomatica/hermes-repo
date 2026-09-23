#!/bin/bash
#
# Build the HERMES nncp binary packages (amd64 and arm64) from the Rhizomatica
# fork of NNCP.
#
# Usage: build-deb.sh [NNCP_SRC] [OUT_DIR]
#   NNCP_SRC  a checkout of github.com/Rhizomatica/nncp at the commit to build
#             (default: ../../../newuucp/nncp)
#   OUT_DIR   where the .deb files go (default: current directory)
#
# Needs: go >= 1.22, aarch64-linux-gnu-gcc (cgo: the hermes PTT keyer uses
# SysV shared memory), dpkg-deb. Upstream fetches recfile from its own module
# proxy, which is not WebPKI-trusted; the go.sum pin still checks the module:
#   GOPROXY=http://proxy.go.stargrave.org GONOSUMDB=go.stargrave.org \
#       go mod download go.stargrave.org/recfile/v4

set -o nounset
set -o errexit
set -o pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "${1:-${here}/../../../newuucp/nncp}" && pwd)"
out="$(mkdir -p "${2:-.}" && cd "${2:-.}" && pwd)"

upstream="$(sed -n 's/^.*Version.* = "\(.*\)"$/\1/p' "${src}/src/nncp.go" | head -n 1)"
commit="$(git -C "${src}" rev-parse --short=7 HEAD)"
# Date and time of the commit, UTC, as one number: two builds on the same
# day then sort by time, not by hash (20260923.04147c2 sorted below
# 20260923.7290b51, so the newer package looked like a downgrade).
date="$(TZ=UTC git -C "${src}" log -1 --format=%cd --date=format-local:%Y%m%d%H%M%S HEAD)"
debrev="${DEBREV:-1rhizomatica1}"
version="${upstream}+git${date}.${commit}-${debrev}"

if [ -n "$(git -C "${src}" status --porcelain --untracked-files=no)" ]; then
    echo "$0: ${src} has uncommitted changes; build from a commit" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

build_arch()
{
    local arch="$1" cc="$2"
    local root="${work}/${arch}"
    mkdir -p "${root}/DEBIAN" "${root}/usr/bin" "${root}/usr/share/doc/nncp"

    local mod
    mod="$(cd "${src}/src" && go list -m)"
    local ldflags="-s -w"
    ldflags="${ldflags} -X ${mod}.DefaultCfgPath=/etc/nncp.hjson"
    ldflags="${ldflags} -X ${mod}.DefaultSendmailPath=/usr/sbin/sendmail"
    ldflags="${ldflags} -X ${mod}.DefaultSpoolPath=/var/spool/nncp"
    ldflags="${ldflags} -X ${mod}.DefaultLogPath=/var/spool/nncp/log"

    (cd "${src}/src" &&
        CGO_ENABLED=1 GOOS=linux GOARCH="${arch}" CC="${cc}" \
            go build -trimpath -o "${root}/usr/bin/nncp" -ldflags "${ldflags}" ./cmd/nncp)

    for cmd in $(cat "${src}/cmd.list"); do
        ln -s nncp "${root}/usr/bin/${cmd}"
    done

    cp "${src}/COPYING" "${root}/usr/share/doc/nncp/copyright"
    gzip -9n -c "${here}/changelog.Debian" > "${root}/usr/share/doc/nncp/changelog.Debian.gz"

    cat > "${root}/DEBIAN/control" << EOF
Package: nncp
Version: ${version}
Architecture: ${arch}
Maintainer: Rafael Diniz <rafael@rhizomatica.org>
Installed-Size: $(du -sk "${root}/usr" | cut -f1)
Conflicts: nncp
Section: net
Priority: optional
Homepage: http://www.nncpgo.org/
Description: Secure store-and-forward files, mail, and commands
 NNCP is a package facilitating secure store-and-forward file and mail
 exchange. It can be thought of as a modern UUCP with Internet smarts.
 .
 Rhizomatica build for HERMES radio stations, from upstream develop
 (git.stargrave.org) plus the fork's HF modem work: native VARA/Mercury
 transport, Hermes SHM and hamlib PTT, per-node nopad and pktv4.
 Built from Rhizomatica/nncp ${commit}.
EOF

    # Create the spool when missing; never change an existing one, whose
    # owner, group and modes the HERMES installer sets (the old postinst
    # reset it to 755 root on every upgrade).
    cat > "${root}/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e

case "$1" in
    configure)
        [ -d /var/spool/nncp ] || install -d -m 0755 /var/spool/nncp
        [ -d /var/spool/nncp/incoming ] || install -d -m 0755 /var/spool/nncp/incoming
    ;;
esac

exit 0
EOF
    chmod 0755 "${root}/DEBIAN/postinst"

    (cd "${root}" && find usr -type f -exec md5sum {} + > DEBIAN/md5sums)

    local deb="${out}/nncp_${version}_${arch}.deb"
    dpkg-deb --root-owner-group --build "${root}" "${deb}" > /dev/null
    echo "${deb}"
}

build_arch amd64 gcc
build_arch arm64 aarch64-linux-gnu-gcc
