# Updating a package in the HERMES repository

How to publish a new version of a package at
<http://debian.hermes.radio/hermes/> (Debian 13 "trixie", `main`,
amd64 and arm64).

Every package is built from **its own source repository**, from that
repository's **default branch** and the `debian/` directory on it; the
repositories are listed in [`list.txt`](list.txt). Nothing is packaged in this
repository itself.

## Before you start

- **Server access:** SSH as `root@debian.hermes.radio`, with your key. Ask
  Rafael to add your public key if you don't have access.
- **Build machines:**
  - amd64: a Debian 13 (trixie) PC;
  - arm64: a Raspberry Pi running Raspberry Pi OS / Debian 13, or a Debian 13
    arm64 chroot under qemu.
  - On both: `sudo apt install devscripts debhelper git`.
- **Server layout:**
  - `/root/hermes-repo-state-20260927` is the reprepro base (`conf/`, `db/`).
    Its `conf/options` publishes straight into the web root
    (`outdir /var/www/html/hermes`), so every command below works in place.
  - `/root/hermes-repo/key/passphrase` is the signing key's passphrase. The
    key itself (EEE8F00A…5DD191BB, "HERMES APT Repo") is in root's keyring.

> **Never run `scripts/upload-repo.sh` on the server.** Run from
> `/root/hermes-repo`, it copies that directory's old `repository/`
> (August 2026) over the web root and silently undoes every publish since.

## 1. Bump the version in the package's repository

On the package repository's **default branch**:

```sh
dch -v 1.2.3-1 "What changed, in one line per change."
git commit -am "debian: 1.2.3-1"
git push
```

Every upload needs a **new version**. The repository refuses a version it
already has with different contents, and keeps only one version of each
package.

## 2. Build the source and amd64 packages

Build on the amd64 machine, from a **clean export** of the default branch:

```sh
git clone https://github.com/Rhizomatica/<package>.git
cd <package>
PKG=$(dpkg-parsechangelog -S Source); VER=$(dpkg-parsechangelog -S Version)
UP=${VER%-*}                                   # upstream version, e.g. 1.2.3
mkdir -p ../build/$PKG-$UP
git archive HEAD | tar -x -C ../build/$PKG-$UP
cd ../build/$PKG-$UP
# "3.0 (quilt)" packages need an orig tarball: the tree without debian/
tar --exclude=./debian -cf - . | gzip -n > ../${PKG}_$UP.orig.tar.gz
sudo apt build-dep ./                          # installs the Build-Depends
debuild --no-lintian -us -uc -sa               # -sa: include the source
```

This leaves the following in `../build/`:
- `<pkg>_<ver>_amd64.changes`, which lists every file of the upload;
- the `.dsc`, `.orig.tar.gz` and `.debian.tar.xz` (the source);
- the `.deb` files and the `.buildinfo`.

## 3. Build the arm64 packages

Build on the arm64 machine, with the same clone steps and the **same**
`.orig.tar.gz`: copy it over, don't regenerate it. Then:

```sh
dpkg-buildpackage -b -us -uc                   # binaries only
```

**Always start from a fresh `git archive`.** A tree that has already been
built on amd64 still contains amd64 objects. The arm64 build then picks them
up and fails, typically with tests "not found".

## 4. Copy everything to the server

```sh
D=/root/incoming-$(date +%Y%m%d)
ssh root@debian.hermes.radio mkdir -p $D
# the amd64 .changes, every file it lists, and the arm64 .deb files
scp <pkg>_<ver>_amd64.changes <pkg>_<ver>.dsc <pkg>_<up>.orig.tar.gz \
    <pkg>_<ver>.debian.tar.xz <pkg>_<ver>_amd64.buildinfo *_amd64.deb \
    *_arm64.deb root@debian.hermes.radio:$D/
```

Check the files arrived intact (`sha256sum` on both sides).

## 5. Publish, on the server

```sh
B=/root/hermes-repo-state-20260927
O="-b $B --ignore=unknownfield"
D=/root/incoming-YYYYMMDD
df -h /                                        # the disk is ~95% full: check it

# back up the database, the published indices, and the package's current
# files: replacing a version deletes the old files from the pool
K=/root/repo-backup-$(date +%Y%m%d-%H%M)
mkdir -p $K && cp -a $B/db $B/conf $K/ && cp -a /var/www/html/hermes/dists $K/
cp -a /var/www/html/hermes/pool/main/*/<pkg> $K/pool-<pkg> 2>/dev/null || true

cd $D
reprepro $O --export=never include trixie <pkg>_<ver>_amd64.changes   # source + amd64
for f in *_arm64.deb; do reprepro $O --export=never includedeb trixie $f; done
reprepro $O list trixie | grep <pkg>           # the new version, amd64 + arm64 + source

# signing: load the passphrase into gpg-agent, export (writes and signs the
# indices), then clear the cache again
KEY=EEE8F00AD242EC5592667F75EA1367BE5DD191BB
echo x | gpg --batch --pinentry-mode loopback \
    --passphrase-file /root/hermes-repo/key/passphrase -u $KEY --clearsign > /dev/null
reprepro $O export trixie
gpg --verify /var/www/html/hermes/dists/trixie/InRelease   # must say "Good signature"
gpgconf --reload gpg-agent
```

If a `.deb` with the same file name is already in the pool with different
contents (a rebuild of the same version), reprepro refuses it. Bump the
version (step 1) rather than forcing it.

## 6. Check it from a station

```sh
sudo apt update
apt policy <pkg>        # "Candidate:" should show the new version
```

## Undoing a publish

Restore the backup from step 5 (`$K`), including the package's old pool files, and
export again:

```sh
cp -a $K/db $K/conf /root/hermes-repo-state-20260927/
P=/var/www/html/hermes/pool/main/<letter>/<pkg>     # e.g. pool/main/p/paq8px
mkdir -p $P && cp -a $K/pool-<pkg>/. $P/
reprepro -b /root/hermes-repo-state-20260927 --ignore=unknownfield export trixie
```

Export needs the gpg-agent priming from step 5 first.

## Package notes

- **mercury** also needs `libwayland-dev`, `libxkbcommon-dev` and
  `libhidapi-dev` installed; they are not in its `debian/control` yet.
  Without `libhidapi-dev` the build silently drops CM108 PTT support.
- **paq8px**: archives can only be read by the version that wrote them, and
  hermes-sensors sends paq8px data between stations. When paq8px changes
  version, upgrade all stations of a network together.
- **nncp** builds from the fork's `hermes` branch (its default). The build
  fetches Go modules over the network; `go.sum` pins them.
