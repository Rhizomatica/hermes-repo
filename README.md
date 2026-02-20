# hermes-repo
HERMES apt / deb repository (reprepro-managed).

## Requirements (build host)
```sh
apt-get install -y reprepro devscripts debhelper gnupg rsync git
```

## Quick start (Debian trixie)
1. Create/import your signing key (you said you'll do this) and decide a key filename to publish (default: `rafael.key`). Place the public key at `repository/rafael.key`.
2. Initialize repo config:
   - Unsigned (local testing): `scripts/repo-init.sh --unsigned`
   - Signed: `scripts/repo-init.sh --sign-with <KEYID>`
3. Build and include everything from `list.txt`:
   - `scripts/build-repo.sh`
   - Or a subset: `scripts/build-repo.sh csdr vvenc`
4. Generate/update the landing page:
   - `scripts/gen-index.sh` (also run automatically by `build-repo.sh`)
5. Publish (example):
   - `scripts/upload-repo.sh --dest user@host:/var/www/html`

## Notes
- The repo is created under `repository/` (contains `conf/ db/ dists/ pool/`), and the landing page is `index.html` at repo root.
- If you build on both amd64 and arm64, make sure you use the same `repository/` state (sync it between machines) before including new packages.

## Common commands
- Build binaries (default, requires build-deps):
  - `scripts/build-repo.sh`
- Build source-only (useful for quick validation):
  - `DPKG_BUILDPACKAGE_OPTS='-S -d' scripts/build-repo.sh csdr`

## Key creation (example)
```sh
gpg --full-generate-key
gpg --list-secret-keys
gpg --armor --export <KEYID> > repository/rafael.key
```

## index.html knobs
```sh
REPO_URL='http://packages.hermes.radio/hermes/' KEY_FILE='rafael.key' scripts/gen-index.sh
```
