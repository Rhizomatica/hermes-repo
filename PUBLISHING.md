# Updating a package in the HERMES repository

How to publish a new version of a package at
<http://debian.hermes.radio/hermes/> (Debian 13 "trixie", `main`,
amd64 and arm64).

Every package is built from **its own source repository**, from that
repository's **default branch** and the `debian/` directory on it; the
repositories are listed in [`list.txt`](list.txt). The repository lives on
the server itself (reprepro base `/root/hermes-repo-state-20260927`,
published in place to `/var/www/html/hermes`). The two tools here work with
it directly:

- `scripts/build-repo.sh --out DIR` builds, and consults the **published**
  repository, not a local one;
- `scripts/publish.sh DIR` uploads, includes, signs and exports on the server.

## Before you start

- **Server access:** SSH as `root@debian.hermes.radio`, with your key. Ask
  Rafael to add your public key if you don't have access.
- **Build machines:**
  - amd64: a Debian 13 (trixie) PC;
  - arm64: the HERMES build Raspberry Pi (Raspberry Pi OS, Debian 13); the
    one used so far is `pi@10.70.96.2`, over the VPN.
  - On both: a clone of this repository, and
    `sudo apt install devscripts debhelper git curl`.
- **Build dependencies:** install the package's `Build-Depends` on each
  machine (`sudo apt build-dep ./` in a checkout of the package).

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

## 2. Build, on amd64 and on arm64

On each build machine, in this repository:

```sh
scripts/build-repo.sh --out ~/upload-amd64 <package>     # on the amd64 PC
scripts/build-repo.sh --out ~/upload-arm64 <package>     # on the Raspberry Pi
```

`<package>` is the repository name from `list.txt`; with no name, every
package is checked.

- A package whose version is **already published** for that architecture is
  skipped.
- The build is from a clean export of the default branch.
- If the server already has the orig tarball for that upstream version, it
  is reused, so a new Debian revision never conflicts with the published one.
- The amd64 build carries the source; the arm64 build is binary-only.
- Each `.changes`, with every file it lists, ends up in the `--out`
  directory.

## 3. Publish

Copy the arm64 directory from the Raspberry Pi to the amd64 machine
(`scp -r pi@10.70.96.2:upload-arm64 ~/`), or run `publish.sh` on each machine.
Then:

```sh
scripts/publish.sh --dry-run ~/upload-amd64 ~/upload-arm64   # what would happen
scripts/publish.sh ~/upload-amd64 ~/upload-arm64
```

It copies the files to the server and checks their checksums there. It then
backs up the database, the published indices and the package's current
pool files to `/root/repo-backup-<date>`. Next it includes the uploads (the
one with the source first), exports and signs once, and checks the
signature. Finally it clears the signing passphrase from gpg-agent and
regenerates the landing page. If an include fails, nothing is exported,
and the error names the backup.

> **Never publish with `scripts/upload-repo.sh`.** It copies a local
> `repository/` over the published one, and on this server it put the August
> 2026 indices back over every publish. It now refuses debian.hermes.radio.

## 4. Check it from a station

```sh
sudo apt update
apt policy <pkg>        # "Candidate:" should show the new version
```

## Undoing a publish

On the server, restore the backup that `publish.sh` printed
(`/root/repo-backup-<date>`), including the package's old pool files
(replacing a version deletes them from the pool). Then export again:

```sh
K=/root/repo-backup-<date>
B=/root/hermes-repo-state-20260927
cp -a $K/db $K/conf $B/
P=/var/www/html/hermes/pool/main/<letter>/<pkg>     # e.g. pool/main/p/paq8px
mkdir -p $P && cp -a $K/pool-<pkg>/. $P/
echo x | gpg --batch --pinentry-mode loopback \
    --passphrase-file /root/hermes-repo/key/passphrase \
    -u EEE8F00AD242EC5592667F75EA1367BE5DD191BB --clearsign > /dev/null
reprepro -b $B --ignore=unknownfield export trixie
gpgconf --reload gpg-agent
```

## Package notes

- **mercury** also needs `libwayland-dev`, `libxkbcommon-dev` and
  `libhidapi-dev` installed; they are not in its `debian/control` yet.
  Without `libhidapi-dev` the build silently drops CM108 PTT support.
- **paq8px**: archives can only be read by the version that wrote them, and
  hermes-sensors sends paq8px data between stations. When paq8px changes
  version, upgrade all stations of a network together.
- **nncp** builds from the fork's `hermes` branch (its default). The build
  fetches Go modules over the network; `go.sum` pins them.
