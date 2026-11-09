# test/test_helper/common.bash - shared setup for the t1-revive bats suite.
# shellcheck shell=bash
#
# Every test runs against synthetic fixtures under test/fixtures and a throw-away state
# directory. Tests that need lib/common.sh or lib/discover.sh call t1r_load, which skips
# (not errors) when the file under test does not exist yet.

T1R_TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
T1R_REPO=$(cd -- "$T1R_TEST_DIR/.." && pwd)
T1R_FIXTURES=$T1R_TEST_DIR/fixtures
export T1R_TEST_DIR T1R_REPO T1R_FIXTURES

# t1r_env: point every T1R_* override at fixtures and a temp dir. Called from setup().
# T1R_TMP is the per-test scratch directory: BATS_TEST_TMPDIR (bats >= 1.4, cleaned up by bats)
# or, on an older bats, a mktemp directory under BATS_RUN_TMPDIR/TMPDIR. Tests use $T1R_TMP and
# never BATS_TEST_TMPDIR directly, so an unset variable can never turn into a path at /.
t1r_env() {
  local tmp=${BATS_TEST_TMPDIR:-}
  [[ -n $tmp ]] || tmp=$(mktemp -d "${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/t1r-test.XXXXXX")
  export T1R_TMP=$tmp
  export T1R_ROOT=$T1R_REPO
  export T1R_STATE=$tmp/state T1R_LOG=$tmp/log T1R_CACHE=$tmp/cache T1R_CONF=$tmp/conf
  export T1R_PREFIX=$tmp/prefix
  mkdir -p "$T1R_STATE" "$T1R_LOG" "$T1R_CACHE" "$T1R_CONF" "$T1R_PREFIX/bin"
  export T1R_LOGFILE=$T1R_LOG/test.log
  : >"$T1R_LOGFILE"
  export T1R_NO_CONFIRM=1 T1R_DEMO=0 T1R_DRY_RUN=1 T1R_COMPONENT=test T1R_COLOR=0
  export T1R_NO_JOURNAL=1   # fixture runs must never land in the real journal
  unset T1R_LSBLK_JSON
  t1r_use_sysfs none
  t1r_use_dmi 14_3
  export T1R_ACPI_TABLES=$T1R_FIXTURES/acpi-none   # does not exist: frst_method must cope
  export TERM=dumb NO_COLOR=1
  t1r_save_bats_run
}

# t1r_save_bats_run: lib/steps/common-steps.sh defines a function called `run` (one-shot.sh's
# step runner), which shadows bats' own `run` helper the moment that file is sourced. Copy
# bats' helper to t1r_run first; tests that source the step code use t1r_run throughout.
t1r_save_bats_run() {
  declare -F run >/dev/null || return 0
  declare -F t1r_run >/dev/null && return 0
  eval "t1r_run() $(declare -f run | tail -n +2)"
}

# t1r_use_sysfs NAME   -> T1R_SYSFS=test/fixtures/sysfs-NAME (recovery|booted-cfg1|booted-cfg2|none)
t1r_use_sysfs() { export T1R_SYSFS=$T1R_FIXTURES/sysfs-$1; }
# t1r_use_dmi NAME     -> T1R_DMI=test/fixtures/dmi-NAME (14_3|13_2|other)
t1r_use_dmi() { export T1R_DMI=$T1R_FIXTURES/dmi-$1; }
# t1r_use_lsblk NAME   -> T1R_LSBLK_JSON=test/fixtures/lsblk-NAME.json
t1r_use_lsblk() { export T1R_LSBLK_JSON=$T1R_FIXTURES/lsblk-$1.json; }

# t1r_load [discover]: source lib/common.sh (and lib/discover.sh) after the T1R_* variables
# are set. Skips the test when the file is not there yet; fails when sourcing itself fails.
t1r_load() {
  local f
  [[ -f $T1R_REPO/lib/common.sh ]] || skip "lib/common.sh not present"
  # shellcheck source=/dev/null
  source "$T1R_REPO/lib/common.sh" || { echo "sourcing lib/common.sh failed" >&2; return 1; }
  for f in "$@"; do
    [[ -f $T1R_REPO/lib/$f.sh ]] || skip "lib/$f.sh not present"
    # shellcheck source=/dev/null
    source "$T1R_REPO/lib/$f.sh" || { echo "sourcing lib/$f.sh failed" >&2; return 1; }
  done
}

# t1r_need FUNC...: fail with a clear message when a contract function is missing.
t1r_need() {
  local f
  for f in "$@"; do
    declare -F "$f" >/dev/null || { echo "contract function not defined: $f" >&2; return 1; }
  done
}

# --- tiny assertions (no bats-assert dependency) -------------------------------------
assert_eq() {  # assert_eq EXPECTED ACTUAL [WHAT]
  [[ $1 == "$2" ]] || { printf '%s\n  expected: %q\n  actual:   %q\n' "${3:-values differ}" "$1" "$2" >&2; return 1; }
}
assert_status() {  # assert_status N   (after `run`)
  [[ $status -eq $1 ]] || { printf 'expected exit %s, got %s\n--- output ---\n%s\n' "$1" "$status" "$output" >&2; return 1; }
}
assert_contains() {  # assert_contains HAYSTACK NEEDLE
  [[ $1 == *"$2"* ]] || { printf 'expected to find %q in:\n%s\n' "$2" "$1" >&2; return 1; }
}
refute_contains() {  # refute_contains HAYSTACK NEEDLE
  [[ $1 != *"$2"* ]] || { printf 'did not expect %q in:\n%s\n' "$2" "$1" >&2; return 1; }
}

# --- fixtures and stubs for the command-level tests -----------------------------------
# t1r_use_osrelease NAME -> T1R_OS_RELEASE=test/fixtures/os-release-NAME (arch|other)
t1r_use_osrelease() { export T1R_OS_RELEASE=$T1R_FIXTURES/os-release-$1; }

# t1r_stub_prefix: fill $T1R_PREFIX with stub executables that echo their arguments and
# append their argv to $T1R_TEST_CALLS, so a test can assert that no device command ran.
# The two marker strings check_idevicerestore greps for are in the stub, as comments.
t1r_stub_prefix() {
  local b
  export T1R_TEST_CALLS=$T1R_TMP/calls.log
  : >"$T1R_TEST_CALLS"
  mkdir -p "$T1R_PREFIX/bin" "$T1R_PREFIX/sbin" "$T1R_PREFIX/lib" "$T1R_PREFIX/lib64"
  for b in bin/idevicerestore bin/irecovery bin/plistutil sbin/usbmuxd; do
    cat >"$T1R_PREFIX/$b" <<'STUB'
#!/usr/bin/env bash
# marker for check_idevicerestore: T1: EmbeddedOS restore options applied
# marker for check_idevicerestore: T1: phase 14 mode
printf '%s %s\n' "${0##*/}" "$*" >>"${T1R_TEST_CALLS:-/dev/null}"
printf 'stub %s\n' "${0##*/}"
printf '%s\n' "$@"
exit 0
STUB
    chmod +x "$T1R_PREFIX/$b"
  done
}

# t1r_calls: everything the stub executables were asked to do (empty when nothing ran).
t1r_calls() { cat "${T1R_TEST_CALLS:-/dev/null}" 2>/dev/null; }

# t1r_fake_esp TEMPLATE: make $T1R_TMP/esp the mountpoint of a synthetic ESP and point
# T1R_LSBLK_JSON at test/fixtures/TEMPLATE.json.tmpl instantiated with it. Sets T1R_ESP_MNT.
t1r_fake_esp() {
  local tmpl=${1:-lsblk-one-esp-mounted}
  export T1R_ESP_MNT=$T1R_TMP/esp
  mkdir -p "$T1R_ESP_MNT"
  sed "s|@ESP_MNT@|$T1R_ESP_MNT|" "$T1R_FIXTURES/$tmpl.json.tmpl" >"$T1R_TMP/lsblk.json"
  export T1R_LSBLK_JSON=$T1R_TMP/lsblk.json
}

# t1r_esp_apple_data: a synthetic EFI/APPLE/EMBEDDEDOS on the fake ESP. Obviously fake
# content: no device data, no long hex runs.
t1r_esp_apple_data() {
  local d=${T1R_ESP_MNT:?t1r_fake_esp first}/EFI/APPLE/EMBEDDEDOS
  mkdir -p "$d"
  printf 'SYNTHETIC-FDR-PLACEHOLDER-NOT-DEVICE-DATA\n' >"$d/FDRData"
  printf '<plist><dict><key>synthetic</key><true/></dict></plist>\n' >"$d/version.plist"
}

# t1r_stub_mount [SRC]: a fake mount(8)/umount(8) pair on PATH for the read-only ESP probe.
# mount copies SRC (default: an empty tree) into the target directory, umount empties it,
# and both append to $T1R_TMP/mount.log. Sets T1R_ESP_PROBE=1 and TMPDIR=$T1R_TMP so the
# probe never needs root or a block device.
t1r_stub_mount() {
  local src=${1:-$T1R_TMP/stub-esp}
  mkdir -p "$src" "$T1R_TMP/bin"
  export T1R_STUB_ESP=$src T1R_ESP_PROBE=1 TMPDIR=$T1R_TMP
  cat >"$T1R_TMP/bin/mount" <<'STUB'
#!/usr/bin/env bash
tgt=${*: -1}
echo "mount $*" >>"$T1R_TMP/mount.log"
cp -a "$T1R_STUB_ESP"/. "$tgt"/
STUB
  cat >"$T1R_TMP/bin/umount" <<'STUB'
#!/usr/bin/env bash
echo "umount $*" >>"$T1R_TMP/mount.log"
find "$1" -mindepth 1 -delete
STUB
  chmod +x "$T1R_TMP/bin/mount" "$T1R_TMP/bin/umount"
  export PATH=$T1R_TMP/bin:$PATH
}

# t1r_stub_pacman: a fake pacman(8) on PATH for the kernel-package checks, plus a fake module
# tree at $T1R_MODULES_DIR. Two files drive it, filled by t1r_pacman_installed (pacman -Q) and
# t1r_pacman_owns (pacman -Qqo). Nothing else about pacman is emulated: any other invocation
# exits 1, so a test can never reach the real package database.
t1r_stub_pacman() {
  export T1R_PACMAN_INSTALLED=$T1R_TMP/pacman-installed T1R_PACMAN_OWNERS=$T1R_TMP/pacman-owners
  : >"$T1R_PACMAN_INSTALLED"
  : >"$T1R_PACMAN_OWNERS"
  export T1R_MODULES_DIR=$T1R_TMP/modules
  mkdir -p "$T1R_MODULES_DIR/$(uname -r)"
  t1r_stub_bin pacman <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -Qqo|-Qo)
    while read -r path pkg; do
      [[ $path == "${2:-}" ]] || continue
      printf '%s\n' "$pkg"; exit 0
    done <"$T1R_PACMAN_OWNERS"
    printf 'error: No package owns %s\n' "${2:-}" >&2; exit 1;;
  -Q|-Qq)
    shift; rc=0
    [[ $# -gt 0 ]] || { cat "$T1R_PACMAN_INSTALLED"; exit 0; }
    for want; do
      line=$(awk -v w="$want" '$1==w{print; exit}' "$T1R_PACMAN_INSTALLED")
      if [[ -n $line ]]; then printf '%s\n' "$line"
      else printf "error: package '%s' was not found\n" "$want" >&2; rc=1; fi
    done
    exit $rc;;
esac
exit 1
STUB
}

# t1r_pacman_installed NAME VERSION: make the stub pacman report NAME as installed.
t1r_pacman_installed() { printf '%s %s\n' "$1" "$2" >>"${T1R_PACMAN_INSTALLED:?t1r_stub_pacman first}"; }

# t1r_pacman_owns PATH PKG: make the stub pacman answer "PKG" for `-Qqo PATH`, and create PATH
# under the fake module tree so the directory tests in lib/distro.sh see it too.
t1r_pacman_owns() {
  printf '%s %s\n' "$1" "$2" >>"${T1R_PACMAN_OWNERS:?t1r_stub_pacman first}"
  case "$1" in */build) mkdir -p "$1" ;; *) mkdir -p "$(dirname -- "$1")"; : >"$1" ;; esac
}

# t1r_kernel_dir: the fake module directory of the running kernel (t1r_stub_pacman/rpm).
t1r_kernel_dir() { printf '%s/%s\n' "${T1R_MODULES_DIR:?t1r_stub_pacman first}" "$(uname -r)"; }

# t1r_stub_rpm: the Fedora counterpart of t1r_stub_pacman - a fake rpm(8) on PATH plus the same
# fake module tree. t1r_rpm_installed fills `rpm -q`, t1r_rpm_owns fills `rpm -qf`. Only the
# query forms lib/distro.sh uses are emulated (-q NAME..., -q --qf FMT NAME, -qf [--qf FMT]
# PATH, where FMT is %{NAME} or %{VERSION}-%{RELEASE}); anything else exits 1.
t1r_stub_rpm() {
  export T1R_RPM_INSTALLED=$T1R_TMP/rpm-installed T1R_RPM_OWNERS=$T1R_TMP/rpm-owners
  : >"$T1R_RPM_INSTALLED"
  : >"$T1R_RPM_OWNERS"
  export T1R_MODULES_DIR=$T1R_TMP/modules
  mkdir -p "$T1R_MODULES_DIR/$(uname -r)"
  t1r_stub_bin rpm <<'STUB'
#!/usr/bin/env bash
fmt=''
fields() {  # fields NAME VERSION-RELEASE -> the requested format (default: NAME-VERSION-RELEASE)
  case "$fmt" in
    '%{NAME}\n') printf '%s\n' "$1" ;;
    '%{VERSION}-%{RELEASE}\n') printf '%s\n' "$2" ;;
    *) printf '%s-%s\n' "$1" "$2" ;;
  esac
}
mode=${1:-}; shift || true
if [[ ${1:-} == --qf ]]; then fmt=$2; shift 2; fi
case "$mode" in
  -qf)
    while read -r path name ver; do
      [[ $path == "${1:-}" ]] || continue
      fields "$name" "$ver"; exit 0
    done <"$T1R_RPM_OWNERS"
    printf 'file %s is not owned by any package\n' "${1:-}"; exit 1;;
  -q)
    rc=0
    for want; do
      # a query matches NAME, or the full NAME-VERSION-RELEASE.ARCH form dnf also accepts
      line=$(awk -v w="$want" '$1==w || $1"-"$2==w || index(w, $1"-"$2".")==1 {print; exit}' "$T1R_RPM_INSTALLED")
      if [[ -n $line ]]; then read -r name ver <<<"$line"; fields "$name" "$ver"
      else printf 'package %s is not installed\n' "$want"; rc=1; fi
    done
    exit $rc;;
esac
exit 1
STUB
}

# t1r_rpm_installed NAME VERSION-RELEASE: make the stub rpm report NAME as installed.
t1r_rpm_installed() { printf '%s %s\n' "$1" "$2" >>"${T1R_RPM_INSTALLED:?t1r_stub_rpm first}"; }

# t1r_rpm_owns PATH NAME VERSION-RELEASE: make the stub rpm answer for `-qf PATH`, and create
# PATH under the fake module tree.
t1r_rpm_owns() {
  printf '%s %s %s\n' "$1" "$2" "$3" >>"${T1R_RPM_OWNERS:?t1r_stub_rpm first}"
  case "$1" in */build) mkdir -p "$1" ;; *) mkdir -p "$(dirname -- "$1")"; : >"$1" ;; esac
}

# t1r_stub_apple_data: a synthetic EFI/APPLE/EMBEDDEDOS in the stub mount's source tree.
t1r_stub_apple_data() {
  local d=${T1R_STUB_ESP:?t1r_stub_mount first}/EFI/APPLE/EMBEDDEDOS
  mkdir -p "$d"
  printf 'SYNTHETIC-FDR-PLACEHOLDER-NOT-DEVICE-DATA\n' >"$d/FDRData"
  printf '<plist><dict><key>synthetic</key><true/></dict></plist>\n' >"$d/version.plist"
  printf 'SYNTHETIC-MEMBOOT-PLACEHOLDER\n' >"$d/combined.memboot"
}

# t1r_step_marker NAME: the done marker run_step would write for step NAME.
t1r_step_marker() {
  install -d -m 700 "$T1R_STATE/private/steps"
  date +%s >"$T1R_STATE/private/steps/$1.done"
}

# t1r_esp_snapshot: remember the exact content of the fake ESP (paths and hashes).
t1r_esp_snapshot() {
  export T1R_ESP_SNAP=$T1R_TMP/esp-snapshot
  t1r_esp_digest >"$T1R_ESP_SNAP"
}

# t1r_esp_digest: "sha256  path" for every file on the fake ESP, sorted.
t1r_esp_digest() {
  ( cd "${T1R_ESP_MNT:?t1r_fake_esp first}" && find . -type f -exec sha256sum {} + 2>/dev/null | sort ) || true
}

# t1r_esp_unchanged: fail when anything on the fake ESP was added, removed or rewritten
# since t1r_esp_snapshot.
t1r_esp_unchanged() {
  local now
  now=$(t1r_esp_digest)
  [[ $now == "$(cat "${T1R_ESP_SNAP:?t1r_esp_snapshot first}")" ]] || {
    printf 'the fake ESP changed.\n--- before ---\n%s\n--- after ---\n%s\n' \
      "$(cat "$T1R_ESP_SNAP")" "$now" >&2; return 1; }
}

# t1r_no_step_markers: fail when a dry run left a step marker behind.
t1r_no_step_markers() {
  local found
  found=$(find "$T1R_STATE/private/steps" -type f 2>/dev/null) || found=''
  [[ -z $found ]] || { printf 'step markers were recorded:\n%s\n' "$found" >&2; return 1; }
}

# t1r_diag_lines: the structured diagnostic lines this run appended to the logs.
t1r_diag_lines() {
  grep -h '^t1-revive-diagnostic ' "$T1R_LOGFILE" "$T1R_LOG"/*.log 2>/dev/null | sort -u || true
}

# t1r_stub_bin NAME: create $T1R_TMP/bin/NAME from stdin and put that directory first in PATH.
# For host commands whose output would otherwise make a test depend on this machine.
t1r_stub_bin() {
  mkdir -p "$T1R_TMP/bin"
  cat >"$T1R_TMP/bin/$1"
  chmod +x "$T1R_TMP/bin/$1"
  case ":$PATH:" in *":$T1R_TMP/bin:"*) ;; *) PATH=$T1R_TMP/bin:$PATH; export PATH;; esac
}
