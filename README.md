# hermes-repo
HERMES apt / deb repository (reprepro-managed).

## Requirements (build host)
```sh
apt-get install -y reprepro devscripts debhelper gnupg rsync git
```

## Quick start (Debian trixie)
1. Create/import your signing key (you said you'll do this) and decide a key filename to publish (default: `hermes.key`). Place the public key at `repository/hermes.key`.
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
- Re-run safely (idempotent):
  - `scripts/build-repo.sh` will skip packages already present in the repo for the current architecture/version.
  - Use `FORCE_REBUILD=1` to rebuild anyway.
    - If `reprepro include` hits a checksum conflict (same version rebuilt differently), the script will remove existing
      binaries for that source+version+arch and retry the include.

## Key creation (example)
```sh
gpg --full-generate-key
gpg --list-secret-keys
gpg --armor --export <KEYID> > repository/hermes.key
```

## Using an existing signing key file
`reprepro` signs using your **GPG keyring** (it does not read `key/*.asc` automatically).

If you already have a secret key export file (example: `key/hermes-repo-signing.secret.asc`):
```sh
gpg --import key/hermes-repo-signing.secret.asc
gpg --list-secret-keys --keyid-format LONG

# then re-export the repo (sign Release files)
reprepro -b repository export trixie
```

## Non-interactive signing (avoid pinentry timeouts)
If you keep a passphrase file at `key/passphrase` (ignored by git), `scripts/build-repo.sh` will automatically prime
`gpg-agent` before `reprepro export` so signing works without interactive pinentry.

## index.html knobs
```sh
REPO_URL='http://debian.hermes.radio/' KEY_FILE='hermes.key' scripts/gen-index.sh
```
