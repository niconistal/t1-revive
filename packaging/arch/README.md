# packaging/arch — the Arch/AUR recipe

`PKGBUILD` builds one package, `t1-revive`: the tool plus the patched libimobiledevice
stack, in a private prefix. Nothing from Apple is downloaded, built or shipped — the
EmbeddedOS firmware is fetched from Apple's CDN by the installed tool at run time and
verified against a pinned checksum.

## What it installs

| path | contents |
| --- | --- |
| `/usr/lib/t1-revive/` | `bin/`, `lib/`, `tools/`, `contrib/`, `skills/`, `VERSION` |
| `/usr/lib/t1-revive/prefix/` | the patched stack: `bin/idevicerestore`, `bin/irecovery`, `bin/plistutil`, `sbin/usbmuxd`, `lib/` |
| `/usr/bin/t1-revive` | symlink to `/usr/lib/t1-revive/bin/t1-revive` |
| `/usr/share/doc/t1-revive/` | `README.md`, `CHANGELOG.md`, `TESTING.md`, `THIRD_PARTY_NOTICES.md`, `docs/` |
| `/usr/share/licenses/t1-revive/` | `LICENSE`, `SOURCES`, `refs.env`, `patches/*.patch`, `vendor/<component>/COPYING*` |

`bin/t1-revive` finds its code under `/usr/lib/t1-revive` on its own, and `lib/common.sh`
defaults `T1R_PREFIX` to `/usr/lib/t1-revive/prefix` when the tree has no `prefix/` of its
own, so the installed layout needs no wrapper and no environment.

## Where the pinned versions come from

The PKGBUILD does **not** repeat the upstream commits, checksums or licences. It sources
the project's `vendor/refs.env` at parse time and builds `source=()` and `sha256sums=()`
from it, so the pins can never drift from what `build.sh` uses. It looks for that file in
two places:

1. `$startdir/refs.env` — a copy next to the PKGBUILD. **This is what an AUR checkout needs**:
   the AUR repository holds `PKGBUILD`, `.SRCINFO` and `refs.env`.
2. `$startdir/../../vendor/refs.env` — the in-tree path, used when you run `makepkg`
   straight from `packaging/arch/` inside a t1-revive checkout.

`prepare()` re-checks the copy against the `vendor/refs.env` that ships inside the release
tarball and fails the build if the two differ, and checks that the `VERSION` file matches
`_relver`.

## Versioning

`VERSION` is `0.1.1`; a pre-release `VERSION` like `0.1.2-dev` cannot be a `pkgver` (no `-`), so the PKGBUILD carries both:

```
_relver=0.1.1         # the git tag is v$_relver, and VERSION must equal this
pkgver=0.1.1          # the Arch version
```

Bump both when `VERSION` changes, and reset `pkgrel=1`.

## The build

`build()` is one line — `bash build.sh --offline --prefix "$srcdir/prefix"`. Everything the
build needs is already unpacked: `prepare()` moves each upstream commit tarball into
`vendor/src/<component>`, and `build.sh` recognises an unpacked tree (no `.git`), applies
`vendor/patches/<component>.patch` with GNU `patch`, and exports `RELEASE_VERSION` from
`refs.env` so the binaries report the same `--version` as a git build. `--offline` makes it
an error for the build to reach the network.

`check()` runs each built binary's `--version` and greps the binary for the T1 patch
markers, so a silently unpatched build cannot ship.

`package()` copies the prefix, deletes the libtool archives and static libraries, rewrites
the RUNPATH of every ELF with `patchelf` and the paths inside the `.pc` and udev files with
`sed`, then refuses to package if any file still points at `$srcdir`.

## Testing it without a release tag

The first source is the release tarball `v$_relver`, which does not exist until the tag is
pushed; its checksum is `SKIP` for the same reason. So a full `makepkg` only works after a
release. What you can do today, all without `sudo`:

```bash
cd packaging/arch

# 1. syntax
bash -n PKGBUILD

# 2. the PKGBUILD parses and the source/checksum arrays come out right
makepkg --printsrcinfo

# 3. the vendored sources download and match their checksums. The project tarball would
#    404 until the tag exists, so verify the eight upstream ones on a copy without it.
#    (Keep the downloads and the work tree out of the repository with SRCDEST/BUILDDIR.)
work=$(mktemp -d)
sed -e 's|^source=("\$_srcdir.*|source=()|' -e "s|^sha256sums=('SKIP')|sha256sums=()|" \
    PKGBUILD > "$work/PKGBUILD"
cp ../../vendor/refs.env "$work/refs.env"
( cd "$work" && SRCDEST="$work/dl" BUILDDIR="$work/bd" makepkg --verifysource )
#   ... libplist-....tar.gz ... Passed   (eight times)

# 4. rehearse build() the way makepkg would, from a clean export of the tree:
mkdir -p "$work/src/t1-revive-0.1.1"
git -C ../.. archive --format=tar HEAD | tar -C "$work/src/t1-revive-0.1.1" -xf -
for t in "$work"/dl/*.tar.gz; do tar -C "$work/src" -xzf "$t"; done   # -> <name>-<commit>/
# rename each <name>-<commit> to vendor/src/<name>, then:
( cd "$work/src/t1-revive-0.1.1" && bash build.sh --offline --prefix "$work/src/prefix" )
```

After the tag exists:

```bash
updpkgsums                 # fills in the SKIP for the project tarball
makepkg --nobuild          # download + verify + prepare(), no compile
makepkg -sri               # the real thing (this one does need sudo/pacman)
namcap PKGBUILD ; namcap t1-revive-*.pkg.tar.zst
makepkg --printsrcinfo > .SRCINFO
```

`.SRCINFO` is deliberately **not** committed to this repository: it is generated, it belongs
to the AUR repository, and it would duplicate the pins that `refs.env` owns.

## Refreshing the upstream pins

Edit `vendor/refs.env` only (commit, version, tarball sha256), rebuild with `build.sh`, then
copy the file next to the PKGBUILD in the AUR repository and regenerate `.SRCINFO`. GitHub
regenerates its `archive/<commit>.tar.gz` files, so if `makepkg` reports a checksum mismatch
on an unchanged commit, re-run `updpkgsums` and update `*_TARBALL_SHA256` in `refs.env` — the
commit sha, not the tarball hash, is the authoritative pin.

## Dependencies

Runtime: `libzip libusb curl openssl readline zlib acpi_call-dkms linux-headers python jq
util-linux`. `acpi_call-dkms` and `linux-headers` are hard dependencies because the T1 reset
(`FRST`) goes through `/proc/acpi/call`; `python` runs the ACPI/plist/pbzx helpers under
`tools/`, `jq` parses `lsblk -J`, `util-linux` provides `lsblk` and `flock`.
Optional: `acpica` (hand-decode ACPI tables when the FRST method is not found), `bats`
(run the test suite from the installed tree).

Build: `autoconf automake libtool pkgconf patch patchelf` plus `base-devel`. `git` is *not*
needed — `build.sh --offline` over unpacked tarballs uses GNU `patch`.

## Other distributions

There is no Debian or Fedora packaging yet. The shape is the same: build `build.sh` into
`/usr/lib/t1-revive/prefix`, install the tree under `/usr/lib/t1-revive`, symlink
`/usr/bin/t1-revive`, and ship `vendor/patches/` plus the `SOURCES` statement to satisfy the
LGPL/GPL source-availability requirement (see `vendor/README.md`).

## Trial build (2026-09-11)

`makepkg -fd` from `packaging/arch/` inside the checkout, with the release tarball provided
locally (`git archive --prefix=t1-revive-0.1.1/ -o $SRCDEST/t1-revive-0.1.1.tar.gz HEAD`,
which makepkg picks up instead of downloading the not-yet-existing tag) and `patchelf` on PATH
from a Python venv (`pip install patchelf`), produced `t1-revive-0.1.0.dev-1-x86_64.pkg.tar.zst`
(0.9 MB) plus a debug package. Verified: `/usr/bin/t1-revive` symlink, `prefix/bin/idevicerestore`
and `prefix/sbin/usbmuxd` present, `RUNPATH` rewritten to `/usr/lib/t1-revive/prefix/lib`, no
build-tree path left in any installed file, `SOURCES` and `refs.env` under the licences
directory. The eight upstream tarball checksums verified. The package has not been installed
(that needs root) and the `t1-revive.conf` sample was added after this trial.

